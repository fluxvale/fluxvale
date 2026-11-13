//! The auth commands (T5 of #362): device-flow sign-in (RFC 8628
//! §3.1–§3.5), status, logout. The wire — the device endpoints and the
//! §3.5 poll machine — lives in the api crate
//! ([`fluxvale_api::device`]); what stays here is the UX around it:
//! the banner, the browser open, the `--scopes` flag, the store seam.
//! The token never prints: [`Token`]'s redaction covers it from the
//! poll's one-time grant to the store (ADR-0019 Am. 3).

use crate::cli::Output;
use crate::reads;
use crate::token::{Token, TokenLocation, TokenStore};
use fluxvale_api::tokens::{MintRequest, MintedToken, TokenClient};
use fluxvale_api::{ApiClient, DeviceClient, poll_loop};
use std::ffi::OsString;
use std::process::{Command, ExitStatus};
use std::time::Duration;

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

/// The `auth login` flags as parsed.
pub struct LoginFlags {
    /// Comma-separated scopes; `None` asks for the full catalog.
    pub scopes: Option<String>,
    /// Don't launch the approval page in a browser.
    pub no_open: bool,
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

/// `--ttl` → seconds. Deliberately small: `s`, `m`, `h`, `d`, one
/// integer each (`30m`, `12h`, `7d`). A bare number is refused —
/// "3600" is ambiguous at a glance, and the platform caps the value
/// at one year anyway (and at the caller token's own expiry).
pub fn parse_ttl(raw: &str) -> anyhow::Result<u64> {
    let normalized = raw.trim().to_ascii_lowercase();
    let invalid = || anyhow::anyhow!("invalid duration {raw:?}: use a value like 30m, 12h, or 7d");
    let (digits, unit_seconds) = [("s", 1u64), ("m", 60), ("h", 3600), ("d", 86_400)]
        .iter()
        .find_map(|(suffix, seconds)| {
            normalized
                .strip_suffix(*suffix)
                .map(|digits| (digits, *seconds))
        })
        .ok_or_else(invalid)?;
    let count: u64 = digits.parse().map_err(|_| invalid())?;
    if count == 0 {
        anyhow::bail!("--ttl must be greater than zero");
    }
    count
        .checked_mul(unit_seconds)
        .ok_or_else(|| anyhow::anyhow!("--ttl is too large"))
}

/// `auth token`: mint a scoped, short-lived credential through the
/// caller's existing sign-in. The raw value stays in [`MintedToken`];
/// the caller prints it once and never writes it to disk.
pub fn mint(
    base_url: &str,
    caller: Token,
    name: Option<&str>,
    scopes: &[String],
    ttl_seconds: u64,
) -> anyhow::Result<MintedToken> {
    TokenClient::new(base_url, caller).mint(&MintRequest {
        name: name.map(str::to_owned),
        scopes: scopes.to_vec(),
        ttl_seconds,
    })
}

/// The stderr line beside the one stdout value: what was minted, with
/// the server's effective scopes and expiry — never the value itself.
pub fn mint_summary(minted: &MintedToken) -> String {
    let scopes = if minted.scopes.is_empty() {
        "no scopes".to_string()
    } else {
        minted.scopes.join(", ")
    };
    format!(
        "minted {:?} — scopes: {scopes}; expires {}",
        minted.name, minted.expires_at
    )
}

/// `auth exec`: run `command` with the stored token in the child's
/// environment ONLY, as `FLUXVALE_PAT`. The token never rides argv,
/// never prints, and the parent shell's environment is untouched. The
/// child's exit status is returned so the caller can pass it through.
/// The child's status as the CLI's own exit code: `None` means
/// success (return normally), a child failure keeps its own code, and
/// a signal death becomes 1. Kept separate from the `process::exit`
/// call so the mapping is testable.
pub fn exit_code(status: ExitStatus) -> Option<i32> {
    match status.code() {
        Some(0) => None,
        Some(code) => Some(code),
        None => Some(1),
    }
}

pub fn exec(
    load: impl FnOnce() -> anyhow::Result<Option<Token>>,
    command: &[OsString],
) -> anyhow::Result<ExitStatus> {
    let Some(token) = load()? else {
        anyhow::bail!("Not signed in. Run `fluxvale auth login` to sign in.")
    };
    let Some((program, args)) = command.split_first() else {
        anyhow::bail!("no command given — run `fluxvale auth exec -- <command>`")
    };

    Command::new(program)
        .args(args)
        .env("FLUXVALE_PAT", token.expose())
        .status()
        .map_err(|err| anyhow::anyhow!("failed to run {}: {err}", program.to_string_lossy()))
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
    /// recorded fragments. (Sleeps are recorded by the api crate's own
    /// poll-machine tests; login only needs *a* sleep closure.)
    struct Recorder {
        fragments: Arc<Mutex<Vec<String>>>,
    }

    fn recorder() -> Recorder {
        Recorder {
            fragments: Arc::new(Mutex::new(Vec::new())),
        }
    }

    impl Recorder {
        fn sleep(&self) -> impl Fn(Duration) {
            |_| {}
        }

        fn notify(&self) -> impl Fn(&str) + '_ {
            let fragments = self.fragments.clone();
            move |fragment| fragments.lock().unwrap().push(fragment.to_string())
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

    // ---- auth exec

    #[cfg(unix)]
    #[test]
    fn exec_puts_the_token_in_the_child_environment_only() {
        let dir = temp_dir();
        let out = dir.join("pat.txt");
        let before = std::env::var("FLUXVALE_PAT").ok();
        let script = format!("printf '%s' \"$FLUXVALE_PAT\" > '{}'", out.display());

        let status = exec(
            || Ok(Some(Token::new("fvpat_child_secret"))),
            &[
                OsString::from("sh"),
                OsString::from("-c"),
                OsString::from(script),
            ],
        )
        .unwrap();

        assert!(status.success());
        assert_eq!(
            std::fs::read_to_string(&out).unwrap(),
            "fvpat_child_secret",
            "the child must see the stored token"
        );
        assert_eq!(
            std::env::var("FLUXVALE_PAT").ok(),
            before,
            "the parent environment must not be mutated"
        );
    }

    #[cfg(unix)]
    #[test]
    fn exec_refuses_without_a_stored_token_and_runs_nothing() {
        let marker = temp_dir().join("ran");
        let script = format!("touch '{}'", marker.display());
        let err = exec(
            || Ok(None),
            &[
                OsString::from("sh"),
                OsString::from("-c"),
                OsString::from(script),
            ],
        )
        .unwrap_err();

        assert!(err.to_string().contains("Not signed in"), "err: {err}");
        assert!(!marker.exists(), "no child may run without a token");
    }

    #[test]
    fn exec_refuses_an_empty_command() {
        let err = exec(|| Ok(Some(Token::new("fvpat_any"))), &[]).unwrap_err();
        assert!(err.to_string().contains("no command given"), "err: {err}");
    }

    #[cfg(unix)]
    #[test]
    fn exec_returns_the_child_status_unchanged() {
        use std::os::unix::process::ExitStatusExt;

        let status = exec(
            || Ok(Some(Token::new("fvpat_any"))),
            &[
                OsString::from("sh"),
                OsString::from("-c"),
                OsString::from("exit 7"),
            ],
        )
        .unwrap();
        assert_eq!(exit_code(status), Some(7));
        assert_eq!(exit_code(ExitStatus::from_raw(0)), None);
        // No exit code (killed by signal 9) maps to 1, not success.
        assert_eq!(exit_code(ExitStatus::from_raw(9)), Some(1));
    }

    #[test]
    fn exec_reports_a_missing_program_without_leaking_the_token() {
        let err = exec(
            || Ok(Some(Token::new("fvpat_never_printed"))),
            &[OsString::from("fluxvale-no-such-program-772")],
        )
        .unwrap_err();

        let message = err.to_string();
        assert!(message.contains("failed to run"), "err: {message}");
        assert!(
            !message.contains("fvpat_never_printed"),
            "leaked: {message}"
        );
    }

    // ---- auth token

    #[test]
    fn parse_ttl_reads_the_four_units_and_refuses_junk() {
        assert_eq!(parse_ttl("30s").unwrap(), 30);
        assert_eq!(parse_ttl("5m").unwrap(), 300);
        assert_eq!(parse_ttl("12h").unwrap(), 43_200);
        assert_eq!(parse_ttl("7d").unwrap(), 604_800);
        // Whitespace and case are forgiven; the unit is what matters.
        assert_eq!(parse_ttl(" 2H ").unwrap(), 7200);

        for raw in [
            "",
            "10",
            "0s",
            "-1h",
            "1.5h",
            "1w",
            "h",
            "999999999999999999999d",
        ] {
            assert!(parse_ttl(raw).is_err(), "{raw:?} must be refused");
        }
    }

    #[test]
    fn mint_wraps_the_token_client() {
        let server = script(vec![respond(
            "201 Created",
            &serde_json::json!({
                "id": "01JTOKEN",
                "name": "ci",
                "access_token": "fvpat_minted_value",
                "token_type": "Bearer",
                "scope": "instances:read",
                "expires_at": "2026-11-13T23:30:00Z"
            }),
        )]);

        let minted = mint(
            &server.base_url,
            Token::new("fvpat_caller"),
            Some("ci"),
            &["instances:read".to_string()],
            60,
        )
        .unwrap();

        assert_eq!(minted.name, "ci");
        assert_eq!(minted.scopes, vec!["instances:read"]);
        assert_eq!(minted.token, Token::new("fvpat_minted_value"));
    }

    #[test]
    fn the_summary_names_the_effective_grant_but_never_the_token() {
        let minted = MintedToken {
            id: "01JTOKEN".to_string(),
            name: "ci-terraform".to_string(),
            token: Token::new("fvpat_never_printed"),
            scopes: vec!["instances:read".to_string(), "backups:read".to_string()],
            expires_at: "2026-11-13T23:30:00Z".to_string(),
        };

        let summary = mint_summary(&minted);
        assert!(summary.contains("ci-terraform"), "summary: {summary}");
        assert!(summary.contains("instances:read, backups:read"));
        assert!(summary.contains("2026-11-13T23:30:00Z"));
        assert!(
            !summary.contains("fvpat_never_printed"),
            "leaked: {summary}"
        );

        let empty = MintedToken {
            scopes: vec![],
            ..minted
        };
        assert!(mint_summary(&empty).contains("no scopes"));
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
