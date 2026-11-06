//! The RFC 8628 device flow (§3.1–§3.5, T5 of #362): mint a sign-in
//! request, then poll for the grant. The device endpoints (#424) are
//! PLAIN JSON — not JSON:API — and unauthenticated by design: the
//! device has no token yet, the flow is how it earns one. The token
//! never prints: [`Token`]'s redaction covers it from the poll's
//! one-time grant on (ADR-0019 Am. 3). Sleeping and printing stay
//! caller-side — [`poll_loop`] takes them as closures.

use crate::token::Token;
use serde_json::{Value, json};
use std::fmt;
use std::time::Duration;

/// The seeded first-party client — the only one the endpoints accept
/// (the server's `device_flow_client_id` config, OQ #9).
const CLIENT_ID: &str = "fluxvale-cli";

/// RFC 8628 §3.5's grant type — the only one the token endpoint speaks.
const GRANT_TYPE: &str = "urn:ietf:params:oauth:grant-type:device_code";

/// RFC 8628 §3.5: after `slow_down`, every subsequent poll waits this
/// many seconds longer.
const SLOW_DOWN_PENALTY_SECS: u64 = 5;

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

#[cfg(test)]
mod tests {
    use super::*;
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

    /// The standard poll-machine closure set: recorded sleeps,
    /// recorded fragments.
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
}
