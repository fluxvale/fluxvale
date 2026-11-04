//! The auth commands (T5 of #362): device-flow sign-in (RFC 8628
//! §3.1–§3.5), status, logout. The device endpoints (#424) are PLAIN
//! JSON — not JSON:API — and unauthenticated by design: the device has
//! no token yet, the flow is how it earns one. The token never prints:
//! [`Token`]'s redaction covers it from the poll's one-time grant to
//! the store (ADR-0019 Am. 3).

use crate::api::ApiClient;
use crate::cli::Output;
use crate::reads;
use crate::token::{Token, TokenLocation, TokenStore};
use serde_json::{Value, json};
use std::fmt;
use std::time::Duration;

/// The seeded first-party client — the only one the endpoints accept
/// (the server's `device_flow_client_id` config, OQ #9).
const CLIENT_ID: &str = "fluxvale-cli";

/// RFC 8628 §3.5's grant type — the only one the token endpoint speaks.
const GRANT_TYPE: &str = "urn:ietf:params:oauth:grant-type:device_code";

/// The S1 scope catalog (FluxVale.Api.Scopes, #360) — login's default
/// request. The server's catalog is the truth; an off-catalog ask is
/// answered by its own `invalid_scope` words, verbatim.
pub const ALL_SCOPES: &[&str] = &[
    "backups:read",
    "backups:write",
    "catalog:read",
    "gateways:read",
    "gateways:write",
    "instances:read",
    "instances:write",
    "wallet:read",
];

/// RFC 8628 §3.5: after `slow_down`, every subsequent poll waits this
/// many seconds longer.
const SLOW_DOWN_PENALTY_SECS: u64 = 5;

/// The `auth login` flags as parsed.
pub struct LoginFlags {
    /// Comma-separated scopes; `None` asks for the full catalog.
    pub scopes: Option<String>,
    /// Don't launch the approval page in a browser.
    pub no_open: bool,
}

impl fmt::Debug for Minted {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // The device_code is the poll capability — redacted like any
        // credential; the rest is the human-facing answer.
        f.debug_struct("Minted")
            .field("device_code", &"***redacted***")
            .field("user_code", &self.user_code)
            .field("verification_uri", &self.verification_uri)
            .field("interval", &self.interval)
            .finish()
    }
}

/// The RFC 8628 §3.1 device authorization response. `expires_in` is
/// not carried: the server owns expiry, and its `expired_token` poll
/// answer is what ends the loop — a client-side clock would only drift.
#[derive(Clone, PartialEq, Eq)]
pub struct Minted {
    /// The poll capability — never printed.
    pub device_code: String,
    /// The human's comparison code — printed BIG.
    pub user_code: String,
    pub verification_uri: String,
    /// Seconds between COUNTED polls (the server's 5).
    pub interval: u64,
}

/// One poll's answer (§3.5).
#[derive(Debug)]
pub enum Poll {
    /// Keep polling.
    Pending,
    /// Back off an extra interval before the next poll.
    SlowDown,
    /// The human said no.
    Denied,
    /// The code expired or was already consumed.
    Expired,
    /// The one-time grant — the raw value lives only inside the
    /// redacted [`Token`].
    Granted { token: Token },
}

/// A client for the two unauthenticated plain-JSON endpoints. No
/// Authorization header rides — there is no token yet.
pub struct DeviceClient {
    agent: ureq::Agent,
    base_url: String,
}

impl DeviceClient {
    pub fn new(base_url: &str) -> Self {
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(30)))
            .build()
            .into();
        DeviceClient {
            agent,
            base_url: base_url.trim_end_matches('/').to_string(),
        }
    }

    /// POST plain JSON, answer (status, body). Errors carry the
    /// server's own OAuth words (`error` + `error_description`).
    fn post(&self, path: &str, body: &Value) -> anyhow::Result<(u16, Value)> {
        let url = format!("{}{}", self.base_url, path);
        let mut response = self
            .agent
            .post(&url)
            .header("Content-Type", "application/json")
            .send(body.to_string().into_bytes())
            .map_err(|err| anyhow::anyhow!("connection failed: {err}"))?;
        let status = response.status().as_u16();
        let raw = response
            .body_mut()
            .read_to_string()
            .map_err(|err| anyhow::anyhow!("connection failed: {err}"))?;
        let body = serde_json::from_str(&raw)
            .map_err(|err| anyhow::anyhow!("HTTP {status}: unreadable body ({err})"))?;
        Ok((status, body))
    }

    /// RFC 8628 §3.1/§3.2 — mint a sign-in request.
    pub fn mint(&self, scopes: &[String]) -> anyhow::Result<Minted> {
        let (status, body) = self.post(
            "/api/v1/device/code",
            &json!({"client_id": CLIENT_ID, "scopes": scopes}),
        )?;
        if status != 200 {
            return Err(oauth_error(status, &body));
        }
        Ok(Minted {
            device_code: string_field(&body, "device_code")?,
            user_code: string_field(&body, "user_code")?,
            verification_uri: string_field(&body, "verification_uri")?,
            interval: body
                .get("interval")
                .and_then(Value::as_u64)
                .ok_or_else(|| anyhow::anyhow!("the mint answer carries no interval"))?,
        })
    }

    /// RFC 8628 §3.5 — one poll.
    pub fn poll(&self, device_code: &str) -> anyhow::Result<Poll> {
        let (status, body) = self.post(
            "/api/v1/device/token",
            &json!({
                "client_id": CLIENT_ID,
                "device_code": device_code,
                "grant_type": GRANT_TYPE,
            }),
        )?;
        if status == 200 {
            let token = Token::new(string_field(&body, "access_token")?);
            return Ok(Poll::Granted { token });
        }
        match body.get("error").and_then(Value::as_str) {
            Some("authorization_pending") => Ok(Poll::Pending),
            Some("slow_down") => Ok(Poll::SlowDown),
            Some("access_denied") => Ok(Poll::Denied),
            Some("expired_token") => Ok(Poll::Expired),
            // invalid_client, unsupported_grant_type, server_error, a
            // non-OAuth body: the server's words surface verbatim.
            _ => Err(oauth_error(status, &body)),
        }
    }
}

fn string_field(body: &Value, field: &str) -> anyhow::Result<String> {
    body.get(field)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| anyhow::anyhow!("the answer carries no {field}"))
}

/// The OAuth §5.2 error shape, one line — both words the server's.
fn oauth_error(status: u16, body: &Value) -> anyhow::Error {
    let code = body.get("error").and_then(Value::as_str).unwrap_or("");
    let description = body.get("error_description").and_then(Value::as_str);
    match (code, description) {
        ("", _) => anyhow::anyhow!("HTTP {status}"),
        (code, Some(description)) => anyhow::anyhow!("{code}: {description}"),
        (code, None) => anyhow::anyhow!("HTTP {status}: {code}"),
    }
}

/// `--scopes` → the request list. No flag asks for the full catalog;
/// the split trims and drops empties — duplicates and off-catalog
/// scopes stay in (the server's `invalid_scope` names them verbatim).
pub fn parse_scopes(flag: Option<&str>) -> anyhow::Result<Vec<String>> {
    match flag {
        None => Ok(ALL_SCOPES.iter().map(|s| (*s).to_owned()).collect()),
        Some(raw) => {
            let scopes: Vec<String> = raw
                .split(',')
                .map(str::trim)
                .filter(|scope| !scope.is_empty())
                .map(str::to_owned)
                .collect();
            if scopes.is_empty() {
                anyhow::bail!("no scopes given in --scopes {raw:?}");
            }
            Ok(scopes)
        }
    }
}

/// What the human sees while the code waits: the page and the code,
/// the code boxed so it can't be missed.
pub fn login_banner(user_code: &str, verification_uri: &str) -> String {
    let rule = "─".repeat(user_code.chars().count() + 4);
    format!(
        "To sign in, open\n\n    {verification_uri}\n\nand enter the code\n\n    ┌{rule}┐\n    │  {user_code}  │\n    └{rule}┘"
    )
}

/// The §3.5 poll machine: poll, honor the server's answers, sleep the
/// interval between polls; `slow_down` grows the interval by 5s for
/// every subsequent poll. `notify` carries the progress dots (boring
/// on purpose); `sleep` is injected so the timing is testable.
pub fn poll_loop(
    client: &DeviceClient,
    device_code: &str,
    interval_secs: u64,
    sleep: impl Fn(Duration),
    notify: impl Fn(&str),
) -> anyhow::Result<Token> {
    // A 0 interval (a broken server) must not busy-loop.
    let mut interval = interval_secs.max(1);
    let mut dots = 0usize;
    let token = loop {
        match client.poll(device_code)? {
            Poll::Pending => {
                notify(".");
                dots += 1;
                sleep(Duration::from_secs(interval));
            }
            Poll::SlowDown => {
                interval += SLOW_DOWN_PENALTY_SECS;
                notify(".");
                dots += 1;
                sleep(Duration::from_secs(interval));
            }
            Poll::Denied => anyhow::bail!("sign-in was denied"),
            Poll::Expired => anyhow::bail!("the code expired — run `fluxvale auth login` again"),
            Poll::Granted { token } => break token,
        }
    };
    if dots > 0 {
        notify("\n");
    }
    Ok(token)
}

/// `auth login`: mint → show the code → open the page (unless
/// `--no-open`) → poll → store → greet. The greet is `whoami`'s own
/// GET /me render. A failed browser launch warns and continues — the
/// page URL is already on screen, the poll keeps running either way.
/// `save` is the store seam (keychain-first in the real command; the
/// tests wire the fallback file so no test ever touches a keychain).
pub fn login(
    base_url: &str,
    flags: &LoginFlags,
    save: impl Fn(&Token) -> anyhow::Result<TokenLocation>,
    open: impl Fn(&str) -> anyhow::Result<()>,
    sleep: impl Fn(Duration),
    notify: impl Fn(&str),
    emit: impl Fn(&str),
) -> anyhow::Result<String> {
    let scopes = parse_scopes(flags.scopes.as_deref())?;
    let client = DeviceClient::new(base_url);
    let minted = client.mint(&scopes)?;
    emit(&login_banner(&minted.user_code, &minted.verification_uri));
    if !flags.no_open
        && let Err(err) = open(&minted.verification_uri)
    {
        notify(&format!("{err}\n"));
    }
    let token = poll_loop(&client, &minted.device_code, minted.interval, sleep, notify)?;
    let location = save(&token)?;
    reads::whoami(&ApiClient::new(base_url, token), location, Output::Table)
}

/// `auth logout`: remove the credential everywhere, then prove it —
/// a load that still answers is a failure, not a shrug. `load`/`delete`
/// are the store seam (the real command passes the keychain-first
/// [`TokenStore`]; tests pass the fallback file).
pub fn logout(
    load: impl Fn() -> anyhow::Result<Option<Token>>,
    delete: impl Fn() -> anyhow::Result<()>,
) -> anyhow::Result<String> {
    let was_signed_in = load()?.is_some();
    delete()?;
    if load()?.is_some() {
        anyhow::bail!("the stored token could not be removed");
    }
    match was_signed_in {
        true => Ok("signed out — the stored token was removed".to_string()),
        false => Ok("not signed in".to_string()),
    }
}

/// The pieces `cli.rs` wires together for logout, kept here so the
/// command stays three lines.
pub fn logout_store(store: &TokenStore, host: &str) -> anyhow::Result<String> {
    logout(
        || Ok(store.load(host)?.map(|(token, _)| token)),
        || store.delete(host),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::token::FileTokenStore;
    use serde_json::json;
    use std::collections::VecDeque;
    use std::io::{Read as _, Write as _};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    fn mint_body(user_code: &str) -> serde_json::Value {
        json!({
            "device_code": "dc_0123456789abcdef0123456789abcdef01234567",
            "user_code": user_code,
            "verification_uri": "https://fluxvale.com/settings/access/device",
            "expires_in": 600,
            "interval": 5
        })
    }

    fn grant_body() -> serde_json::Value {
        json!({
            "access_token": "fvpat_raw_token_value_from_the_wire",
            "token_type": "Bearer",
            "scope": "instances:read wallet:read",
            "expires_in": 31536000
        })
    }

    // ---- the scripted server (writes.rs's pattern): one canned
    // response per connection, every request captured.

    struct Script {
        base_url: String,
        requests: Arc<Mutex<Vec<String>>>,
    }

    fn script(responses: Vec<String>) -> Script {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let captured = requests.clone();
        let mut responses = VecDeque::from(responses);
        std::thread::spawn(move || {
            while let Some(response) = responses.pop_front() {
                let Ok((mut stream, _)) = listener.accept() else {
                    break;
                };
                let mut raw = Vec::new();
                let mut buf = [0u8; 8192];
                loop {
                    let read = stream.read(&mut buf).unwrap();
                    if read == 0 {
                        break;
                    }
                    raw.extend_from_slice(&buf[..read]);
                    if let Some(end) = head_end(&raw) {
                        let length = content_length(&raw);
                        if raw.len() >= end + length {
                            break;
                        }
                    }
                }
                captured
                    .lock()
                    .unwrap()
                    .push(String::from_utf8_lossy(&raw).to_string());
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.flush();
            }
        });
        Script {
            base_url: format!("http://{addr}"),
            requests,
        }
    }

    fn head_end(raw: &[u8]) -> Option<usize> {
        raw.windows(4).position(|w| w == b"\r\n\r\n").map(|p| p + 4)
    }

    fn content_length(raw: &[u8]) -> usize {
        String::from_utf8_lossy(raw)
            .to_lowercase()
            .split("\r\n")
            .find_map(|line| {
                line.strip_prefix("content-length: ")
                    .map(|v| v.trim().parse().ok())
            })
            .flatten()
            .unwrap_or(0)
    }

    fn respond(status_line: &str, body: &serde_json::Value) -> String {
        let body = body.to_string();
        let mut response = format!("HTTP/1.1 {status_line}\r\n");
        response.push_str(&format!("Content-Length: {}\r\n", body.len()));
        response.push_str("Connection: close\r\n\r\n");
        response.push_str(&body);
        response
    }

    fn captured_requests(server: &Script) -> Vec<String> {
        server
            .requests
            .lock()
            .unwrap()
            .iter()
            .map(|raw| raw.to_lowercase())
            .collect()
    }

    /// The standard login closure set: file-store save, no-op open,
    /// recorded sleeps, recorded fragments.
    struct Recorder {
        sleeps: Arc<Mutex<Vec<Duration>>>,
        fragments: Arc<Mutex<Vec<String>>>,
    }

    fn recorder() -> Recorder {
        Recorder {
            sleeps: Arc::new(Mutex::new(Vec::new())),
            fragments: Arc::new(Mutex::new(Vec::new())),
        }
    }

    impl Recorder {
        fn sleep(&self) -> impl Fn(Duration) + '_ {
            let sleeps = self.sleeps.clone();
            move |duration| sleeps.lock().unwrap().push(duration)
        }

        fn notify(&self) -> impl Fn(&str) + '_ {
            let fragments = self.fragments.clone();
            move |fragment| fragments.lock().unwrap().push(fragment.to_string())
        }

        fn slept(&self) -> Vec<Duration> {
            self.sleeps.lock().unwrap().clone()
        }

        fn fragments(&self) -> Vec<String> {
            self.fragments.lock().unwrap().clone()
        }

        /// Everything printed, joined — for never-leaks assertions.
        fn joined(&self) -> String {
            self.fragments().join("")
        }
    }

    fn file_save<'a>(
        dir: &'a std::path::Path,
        host: &'a str,
    ) -> impl Fn(&Token) -> anyhow::Result<TokenLocation> + 'a {
        move |token| {
            let store = FileTokenStore::at(dir.to_path_buf());
            store.set(host, token)?;
            Ok(TokenLocation::FallbackFile)
        }
    }

    // ---- DeviceClient against the mock server

    #[test]
    fn mint_posts_the_client_and_scopes_and_parses_the_rfc_payload() {
        let server = script(vec![respond("200 OK", &mint_body("ABCD-EFGH"))]);
        let client = DeviceClient::new(&server.base_url);
        let minted = client.mint(&["instances:read".to_string()]).unwrap();
        assert_eq!(minted.user_code, "ABCD-EFGH");
        assert_eq!(
            minted.verification_uri,
            "https://fluxvale.com/settings/access/device"
        );
        assert_eq!(minted.interval, 5);

        let head = captured_requests(&server).remove(0);
        assert!(
            head.starts_with("post /api/v1/device/code http/1.1"),
            "head: {head}"
        );
        assert!(
            head.contains("\"client_id\":\"fluxvale-cli\""),
            "head: {head}"
        );
        assert!(
            head.contains("\"scopes\":[\"instances:read\"]"),
            "head: {head}"
        );
        assert!(
            !head.contains("authorization:"),
            "the flow is unauthenticated by design: {head}"
        );
        assert!(
            head.contains("content-type: application/json"),
            "head: {head}"
        );
    }

    #[test]
    fn mint_refusals_carry_the_server_words() {
        let server = script(vec![respond(
            "400 Bad Request",
            &json!({"error": "invalid_scope", "error_description": "unknown scope wallet:write"}),
        )]);
        let err = DeviceClient::new(&server.base_url)
            .mint(&["wallet:write".to_string()])
            .unwrap_err();
        let text = err.to_string();
        assert!(text.contains("invalid_scope"), "text: {text}");
        assert!(text.contains("unknown scope wallet:write"), "text: {text}");
    }

    #[test]
    fn poll_maps_every_rfc_outcome() {
        for (error, expected) in [
            ("authorization_pending", "pending"),
            ("slow_down", "slow"),
            ("access_denied", "denied"),
            ("expired_token", "expired"),
        ] {
            let server = script(vec![respond(
                "400 Bad Request",
                &json!({"error": error, "error_description": "…"}),
            )]);
            let answer = DeviceClient::new(&server.base_url).poll("dc").unwrap();
            let seen = match answer {
                Poll::Pending => "pending",
                Poll::SlowDown => "slow",
                Poll::Denied => "denied",
                Poll::Expired => "expired",
                Poll::Granted { .. } => "granted",
            };
            assert_eq!(seen, expected, "{error} must map to {expected}");
        }
    }

    #[test]
    fn poll_grant_wraps_the_raw_value_in_the_redacted_token() {
        let server = script(vec![respond("200 OK", &grant_body())]);
        let answer = DeviceClient::new(&server.base_url).poll("dc").unwrap();
        // Debug never leaks the raw value.
        let debug_form = format!("{answer:?}");
        assert!(
            !debug_form.contains("fvpat_raw_token_value_from_the_wire"),
            "the grant's Debug leaked the token"
        );
        let Poll::Granted { token } = answer else {
            panic!("expected the grant");
        };
        assert_eq!(token, Token::new("fvpat_raw_token_value_from_the_wire"));
        // The poll body rides the RFC grant type.
        let head = captured_requests(&server).remove(0);
        assert!(
            head.starts_with("post /api/v1/device/token http/1.1"),
            "head: {head}"
        );
        assert!(
            head.contains("\"grant_type\":\"urn:ietf:params:oauth:grant-type:device_code\""),
            "head: {head}"
        );
    }

    #[test]
    fn poll_unknown_errors_surface_the_server_words() {
        let server = script(vec![respond(
            "400 Bad Request",
            &json!({"error": "invalid_client", "error_description": "unknown client"}),
        )]);
        let err = DeviceClient::new(&server.base_url).poll("dc").unwrap_err();
        assert!(
            err.to_string().contains("invalid_client: unknown client"),
            "err: {err}"
        );
    }

    // ---- the poll machine: injected sleep, scripted answers

    #[test]
    fn the_poll_loop_sleeps_the_interval_and_backs_off_after_slow_down() {
        // interval 5 from the mint; slow_down raises it to 10 for every
        // subsequent poll (§3.5). The injected sleep makes the timing
        // exact without waiting.
        let server = script(vec![
            respond(
                "400 Bad Request",
                &json!({"error": "authorization_pending"}),
            ),
            respond("400 Bad Request", &json!({"error": "slow_down"})),
            respond("200 OK", &grant_body()),
        ]);
        let rec = recorder();
        let token = poll_loop(
            &DeviceClient::new(&server.base_url),
            "dc",
            5,
            rec.sleep(),
            rec.notify(),
        )
        .unwrap();
        assert_eq!(
            rec.slept(),
            vec![Duration::from_secs(5), Duration::from_secs(10)]
        );
        // Two dots + the closing newline; the raw token never prints.
        assert_eq!(rec.joined(), "..\n");
        assert!(
            !rec.joined().contains("fvpat_raw_token_value_from_the_wire"),
            "the loop leaked the token"
        );
        assert_eq!(token, Token::new("fvpat_raw_token_value_from_the_wire"));
    }

    #[test]
    fn the_poll_loop_silence_when_granted_without_a_wait() {
        let server = script(vec![respond("200 OK", &grant_body())]);
        let rec = recorder();
        poll_loop(
            &DeviceClient::new(&server.base_url),
            "dc",
            5,
            rec.sleep(),
            rec.notify(),
        )
        .unwrap();
        assert!(rec.slept().is_empty());
        assert_eq!(rec.joined(), "", "no dots when no poll was waited");
    }

    #[test]
    fn denied_and_expired_exit_with_their_lines() {
        let server = script(vec![
            respond(
                "400 Bad Request",
                &json!({"error": "authorization_pending"}),
            ),
            respond("400 Bad Request", &json!({"error": "access_denied"})),
        ]);
        let rec = recorder();
        let err = poll_loop(
            &DeviceClient::new(&server.base_url),
            "dc",
            5,
            rec.sleep(),
            rec.notify(),
        )
        .unwrap_err();
        assert_eq!(err.to_string(), "sign-in was denied");

        let server = script(vec![respond(
            "400 Bad Request",
            &json!({"error": "expired_token"}),
        )]);
        let rec = recorder();
        let err = poll_loop(
            &DeviceClient::new(&server.base_url),
            "dc",
            5,
            rec.sleep(),
            rec.notify(),
        )
        .unwrap_err();
        assert_eq!(
            err.to_string(),
            "the code expired — run `fluxvale auth login` again"
        );
    }

    #[test]
    fn a_zero_interval_is_clamped_so_the_loop_cannot_busy_spin() {
        let server = script(vec![
            respond(
                "400 Bad Request",
                &json!({"error": "authorization_pending"}),
            ),
            respond("200 OK", &grant_body()),
        ]);
        let rec = recorder();
        poll_loop(
            &DeviceClient::new(&server.base_url),
            "dc",
            0,
            rec.sleep(),
            rec.notify(),
        )
        .unwrap();
        assert_eq!(rec.slept(), vec![Duration::from_secs(1)]);
    }

    // ---- login end-to-end against the mock: mint → grant → /me,
    // the token stored through the file seam.

    fn me_body() -> serde_json::Value {
        json!({
            "data": {"type": "user", "id": "01H",
                     "attributes": {"email": "me@example.com", "platform_role": "user"}}
        })
    }

    // The greet's discovery read (T6a): whoami rides /organizations
    // after /me. Empty keeps the greet line exactly the /me sentence —
    // whoami prints no org section when the list is empty.
    fn orgs_body() -> serde_json::Value {
        json!({"data": []})
    }

    #[test]
    fn login_end_to_end_stores_the_token_and_greets() {
        let server = script(vec![
            respond("200 OK", &mint_body("WXYZ-VKLM")),
            respond("200 OK", &grant_body()),
            respond("200 OK", &me_body()),
            respond("200 OK", &orgs_body()),
        ]);
        let dir = temp_dir();
        let rec = recorder();
        let final_line = login(
            &server.base_url,
            &LoginFlags {
                scopes: None,
                no_open: true,
            },
            file_save(&dir, "127.0.0.1:token-test"),
            |_| panic!("no_open must not launch a browser"),
            rec.sleep(),
            rec.notify(),
            rec.notify(),
        )
        .unwrap();
        assert_eq!(
            final_line,
            "signed in as me@example.com via the credentials file"
        );

        // The stored token round-trips — and its raw value appears
        // NOWHERE in what was printed.
        let stored = FileTokenStore::at(dir.clone())
            .get("127.0.0.1:token-test")
            .unwrap()
            .unwrap();
        assert_eq!(stored, Token::new("fvpat_raw_token_value_from_the_wire"));
        let printed = rec.joined();
        assert!(printed.contains("WXYZ-VKLM"), "printed: {printed}");
        assert!(
            printed.contains("settings/access/device"),
            "printed: {printed}"
        );
        assert!(
            !printed.contains("fvpat_raw_token_value_from_the_wire"),
            "login leaked the token: {printed}"
        );
        assert!(
            !format!("{stored:?}").contains("fvpat_raw_token_value_from_the_wire"),
            "Debug leaked"
        );

        // The /me read rode the minted token — and the discovery read
        // (T6a) followed it.
        let me_head = &captured_requests(&server)[2];
        assert!(
            me_head.starts_with("get /api/v1/me http/1.1"),
            "me: {me_head}"
        );
        assert!(
            me_head.contains("authorization: bearer fvpat_raw_token_value_from_the_wire"),
            "me: {me_head}"
        );
        let orgs_head = &captured_requests(&server)[3];
        assert!(
            orgs_head.starts_with("get /api/v1/organizations http/1.1"),
            "orgs: {orgs_head}"
        );
    }

    #[test]
    fn login_opens_the_page_by_default_and_survives_a_failed_launch() {
        for launch_fails in [false, true] {
            let server = script(vec![
                respond("200 OK", &mint_body("OPEN-CODE")),
                respond("200 OK", &grant_body()),
                respond("200 OK", &me_body()),
                respond("200 OK", &orgs_body()),
            ]);
            let dir = temp_dir();
            let rec = recorder();
            let opened = Arc::new(Mutex::new(None));
            let captured = opened.clone();
            let final_line = login(
                &server.base_url,
                &LoginFlags {
                    scopes: None,
                    no_open: false,
                },
                file_save(&dir, "127.0.0.1:token-test"),
                move |url| {
                    *captured.lock().unwrap() = Some(url.to_string());
                    if launch_fails {
                        Err(anyhow::anyhow!("no browser here"))
                    } else {
                        Ok(())
                    }
                },
                rec.sleep(),
                rec.notify(),
                rec.notify(),
            )
            .unwrap();
            assert_eq!(
                opened.lock().unwrap().as_deref(),
                Some("https://fluxvale.com/settings/access/device")
            );
            // A failed launch warns on the progress channel — and the
            // flow completes: the URL is already on screen.
            if launch_fails {
                assert!(
                    rec.joined().contains("no browser here"),
                    "fragments: {}",
                    rec.joined()
                );
            }
            assert!(final_line.contains("signed in as"));
        }
    }

    #[test]
    fn login_with_scopes_asks_for_exactly_those() {
        let server = script(vec![respond(
            "400 Bad Request",
            &json!({"error": "invalid_scope", "error_description": "unknown scope nope:read"}),
        )]);
        let rec = recorder();
        let dir = temp_dir();
        let err = login(
            &server.base_url,
            &LoginFlags {
                scopes: Some("instances:read, nope:read".to_string()),
                no_open: true,
            },
            file_save(&dir, "127.0.0.1:token-test"),
            |_| panic!("no_open must not launch a browser"),
            rec.sleep(),
            rec.notify(),
            rec.notify(),
        )
        .unwrap_err();
        assert!(
            err.to_string().contains("unknown scope nope:read"),
            "err: {err}"
        );
        let head = captured_requests(&server).remove(0);
        assert!(
            head.contains("\"scopes\":[\"instances:read\",\"nope:read\"]"),
            "trimmed, in order: {head}"
        );
    }

    // ---- scopes + banner

    #[test]
    fn parse_scopes_defaults_to_the_full_catalog_and_splits_commas() {
        let default = parse_scopes(None).unwrap();
        assert_eq!(default.len(), ALL_SCOPES.len());
        assert_eq!(default[0], "backups:read");
        assert_eq!(
            parse_scopes(Some("a:b , c:d,,  ")).unwrap(),
            vec!["a:b".to_string(), "c:d".to_string()]
        );
        let err = parse_scopes(Some(" , ")).unwrap_err();
        assert!(err.to_string().contains("no scopes given"), "err: {err}");
        // Every catalog entry rides the default — nothing forgotten.
        for scope in ["instances:write", "wallet:read", "catalog:read"] {
            assert!(default.iter().any(|s| s == scope), "{scope} missing");
        }
    }

    #[test]
    fn the_banner_boxes_the_code_and_names_the_page() {
        let banner = login_banner("ABCD-EFGH", "https://fluxvale.com/settings/access/device");
        assert!(banner.contains("https://fluxvale.com/settings/access/device"));
        assert!(banner.contains("│  ABCD-EFGH  │"), "banner:\n{banner}");
        // Every box line is the same width (the code drives it).
        let widths: Vec<usize> = banner
            .lines()
            .filter(|line| line.contains('┌') || line.contains('└') || line.contains('│'))
            .map(|line| line.chars().count())
            .collect();
        assert_eq!(widths.len(), 3, "three box lines expected: {banner}");
        assert!(
            widths.windows(2).all(|w| w[0] == w[1]),
            "uneven box: {banner}"
        );
    }

    // ---- logout against the file store

    #[test]
    fn logout_removes_and_confirms_and_stays_honest_when_absent() {
        let dir = temp_dir();
        let store = FileTokenStore::at(dir);
        store.set("fluxvale.com", &Token::new("fvpat_a")).unwrap();
        store
            .set("staging.fluxvale.com", &Token::new("fvpat_b"))
            .unwrap();

        let load = || Ok(store.get("fluxvale.com").unwrap());
        let delete = || store.remove("fluxvale.com");
        let line = logout(load, delete).unwrap();
        assert_eq!(line, "signed out — the stored token was removed");
        assert!(store.get("fluxvale.com").unwrap().is_none());
        // The other host's credential survives.
        assert!(store.get("staging.fluxvale.com").unwrap().is_some());

        // Logging out again is a clean no-op, not an error.
        let load = || Ok(store.get("fluxvale.com").unwrap());
        let delete = || store.remove("fluxvale.com");
        assert_eq!(logout(load, delete).unwrap(), "not signed in");
    }

    fn temp_dir() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "fluxvale-cli-auth-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }
}
