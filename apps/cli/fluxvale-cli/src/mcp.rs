//! The `fluxvale mcp` commands (login, logout, status): OAuth 2.0 device grant
//! with mandatory PKCE (`S256`) against `/oauth/device/code` and `/oauth/token`.
//! Wire transport and the poll state machine live in [`fluxvale_api::oauth`];
//! stored pairs live in [`McpTokenStore`].

use crate::auth;
use crate::token::{McpCredentials, McpTokenStore, TokenLocation};
use fluxvale_api::{OAuthDeviceClient, PkceVerifier, oauth_poll_loop};
use std::time::Duration;

/// The `mcp login` flags as parsed.
pub struct McpLoginFlags {
    /// Comma-separated scopes; `None` asks for the full catalog.
    pub scopes: Option<String>,
    /// Optional RFC 8707 target MCP resource URL.
    pub resource: Option<String>,
    /// Don't launch the approval page in a browser.
    pub no_open: bool,
}

fn storage_label(location: TokenLocation) -> &'static str {
    match location {
        TokenLocation::Keychain => "the OS keychain",
        TokenLocation::FallbackFile => "the MCP credentials file",
    }
}

/// Human-facing prompt shown while waiting for device grant approval.
pub fn mcp_login_banner(user_code: &str, verification_uri: &str) -> String {
    let rule = "─".repeat(user_code.chars().count() + 4);
    format!(
        "To authorize MCP access, open\n\n    {verification_uri}\n\nand confirm the code\n\n    ┌{rule}┐\n    │  {user_code}  │\n    └{rule}┘"
    )
}

/// `mcp login`: mint with PKCE S256, show banner, open browser (unless `--no-open`),
/// poll `/oauth/token`, persist the token pair, and return a confirmation line.
#[allow(clippy::too_many_arguments)]
pub fn login(
    base_url: &str,
    host: &str,
    flags: &McpLoginFlags,
    save: impl Fn(&McpCredentials) -> anyhow::Result<TokenLocation>,
    open: impl Fn(&str) -> anyhow::Result<()>,
    sleep: impl Fn(Duration),
    notify: impl Fn(&str),
    emit: impl Fn(&str),
    now: impl Fn() -> u64,
) -> anyhow::Result<String> {
    let scopes = auth::parse_scopes(flags.scopes.as_deref())?;
    let verifier = PkceVerifier::generate();
    let client = OAuthDeviceClient::new(base_url);
    let minted = client.mint(&scopes, flags.resource.as_deref(), &verifier.challenge())?;

    let display_uri = minted
        .verification_uri_complete
        .as_deref()
        .unwrap_or(&minted.verification_uri);
    emit(&mcp_login_banner(&minted.user_code, display_uri));

    if !flags.no_open
        && let Err(err) = open(display_uri)
    {
        notify(&format!("{err}\n"));
    }

    let pair = oauth_poll_loop(
        &client,
        &minted.device_code,
        verifier.expose(),
        minted.interval,
        sleep,
        notify,
    )?;

    let creds = McpCredentials {
        access_token: pair.access_token,
        refresh_token: pair.refresh_token,
        expires_at_unix: now().saturating_add(pair.expires_in),
        scope: pair.scope,
        resource: flags.resource.clone(),
    };
    let location = save(&creds)?;
    let scope_summary = if creds.scope.is_empty() {
        "none".to_string()
    } else {
        creds.scope.clone()
    };

    Ok(format!(
        "signed in for MCP on {host} via {}, scopes: {scope_summary}",
        storage_label(location)
    ))
}

/// `mcp logout`: remove stored MCP credentials everywhere, then verify removal.
pub fn logout(
    load: impl Fn() -> anyhow::Result<Option<McpCredentials>>,
    delete: impl Fn() -> anyhow::Result<()>,
) -> anyhow::Result<String> {
    // A failed pre-check must not block removal of a corrupt entry.
    let was_signed_in = !matches!(load(), Ok(None));
    delete()?;
    if load()?.is_some() {
        anyhow::bail!("the stored MCP credentials could not be removed");
    }
    match was_signed_in {
        true => Ok("signed out of MCP, stored credentials were removed".to_string()),
        false => Ok("not signed in for MCP".to_string()),
    }
}

/// Convenience wrapper wiring [`McpTokenStore`] into [`logout`].
pub fn logout_store(store: &McpTokenStore, host: &str) -> anyhow::Result<String> {
    logout(
        || Ok(store.load(host)?.map(|(creds, _)| creds)),
        || store.delete(host),
    )
}

/// `mcp status`: report whether MCP credentials are stored for `host`,
/// storage location, scopes, resource, and expiry state without ever printing tokens.
pub fn status(
    host: &str,
    now_unix: u64,
    load: impl FnOnce() -> anyhow::Result<Option<(McpCredentials, TokenLocation)>>,
) -> anyhow::Result<String> {
    let Some((creds, location)) = load()? else {
        return Ok(format!(
            "not signed in for MCP on {host}, run `fluxvale mcp login` to sign in"
        ));
    };

    let scopes = if creds.scope.is_empty() {
        "none"
    } else {
        creds.scope.as_str()
    };
    let resource = creds.resource.as_deref().unwrap_or("default");
    let expiry = format_expiry(creds.expires_at_unix, now_unix);

    Ok(format!(
        "signed in for MCP on {host} via {}\nscopes: {scopes}\nresource: {resource}\nstatus: {expiry}",
        storage_label(location)
    ))
}

/// Convenience wrapper wiring [`McpTokenStore`] into [`status`].
pub fn status_store(store: &McpTokenStore, host: &str, now_unix: u64) -> anyhow::Result<String> {
    status(host, now_unix, || store.load(host))
}

fn format_expiry(expires_at_unix: u64, now_unix: u64) -> String {
    if now_unix >= expires_at_unix {
        let ago = now_unix - expires_at_unix;
        format!("expired ({ago}s ago, refresh token available)")
    } else {
        let remaining = expires_at_unix - now_unix;
        format!("active (access token expires in {remaining}s)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::token::{FileMcpTokenStore, Token};
    use fluxvale_api::pkce_challenge;
    use serde_json::{Value, json};
    use std::collections::VecDeque;
    use std::io::{Read as _, Write as _};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    const SECRET_DEVICE_CODE: &str = "dc_secret_device_code_never_leaked_123456";
    const SECRET_ACCESS_TOKEN: &str = "fvoat_secret_access_token_never_leaked";
    const SECRET_REFRESH_TOKEN: &str = "fvort_secret_refresh_token_never_leaked";

    fn mint_body(user_code: &str, include_complete: bool) -> Value {
        let mut map = serde_json::Map::new();
        map.insert("device_code".to_string(), json!(SECRET_DEVICE_CODE));
        map.insert("user_code".to_string(), json!(user_code));
        map.insert(
            "verification_uri".to_string(),
            json!("https://fluxvale.com/oauth/device"),
        );
        if include_complete {
            map.insert(
                "verification_uri_complete".to_string(),
                json!(format!(
                    "https://fluxvale.com/oauth/device?user_code={user_code}"
                )),
            );
        }
        map.insert("expires_in".to_string(), json!(600));
        map.insert("interval".to_string(), json!(5));
        Value::Object(map)
    }

    fn token_pair_body(scope: &str) -> Value {
        json!({
            "access_token": SECRET_ACCESS_TOKEN,
            "refresh_token": SECRET_REFRESH_TOKEN,
            "token_type": "Bearer",
            "expires_in": 3600,
            "scope": scope
        })
    }

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

    fn respond(status_line: &str, body: &Value) -> String {
        let body = body.to_string();
        let mut response = format!("HTTP/1.1 {status_line}\r\n");
        response.push_str(&format!("Content-Length: {}\r\n", body.len()));
        response.push_str("Connection: close\r\n\r\n");
        response.push_str(&body);
        response
    }

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

        fn joined(&self) -> String {
            self.fragments.lock().unwrap().join("")
        }
    }

    fn file_save<'a>(
        dir: &'a std::path::Path,
        host: &'a str,
    ) -> impl Fn(&McpCredentials) -> anyhow::Result<TokenLocation> + 'a {
        move |creds| {
            let store = FileMcpTokenStore::at(dir.to_path_buf());
            store.set(host, creds)?;
            Ok(TokenLocation::FallbackFile)
        }
    }

    fn form_param(body: &str, key: &str) -> Option<String> {
        body.split('&').find_map(|pair| {
            let (k, v) = pair.split_once('=')?;
            if k == key { Some(v.to_string()) } else { None }
        })
    }

    #[test]
    fn login_end_to_end_pkce_round_trip_and_never_leaks_secrets() {
        let server = script(vec![
            respond("200 OK", &mint_body("WXYZ-VKLM", true)),
            respond(
                "400 Bad Request",
                &json!({"error": "authorization_pending"}),
            ),
            respond("200 OK", &token_pair_body("instances:read wallet:read")),
        ]);
        let dir = temp_dir();
        let rec = recorder();
        let final_line = login(
            &server.base_url,
            "fluxvale.com",
            &McpLoginFlags {
                scopes: None,
                resource: None,
                no_open: true,
            },
            file_save(&dir, "fluxvale.com"),
            |_| panic!("no_open must not launch a browser"),
            rec.sleep(),
            rec.notify(),
            rec.notify(),
            || 1_700_000_000,
        )
        .unwrap();

        assert_eq!(
            final_line,
            "signed in for MCP on fluxvale.com via the MCP credentials file, scopes: instances:read wallet:read"
        );
        assert!(!final_line.contains('—'));
        assert!(!final_line.contains(';'));

        // Verify stored pair round-trips.
        let stored = FileMcpTokenStore::at(dir)
            .get("fluxvale.com")
            .unwrap()
            .unwrap();
        assert_eq!(stored.access_token, Token::new(SECRET_ACCESS_TOKEN));
        assert_eq!(stored.refresh_token, Token::new(SECRET_REFRESH_TOKEN));
        assert_eq!(stored.expires_at_unix, 1_700_003_600);
        assert_eq!(stored.scope, "instances:read wallet:read");
        assert_eq!(stored.resource, None);

        // Verify mint JSON + S256 challenge matches poll form-encoded code_verifier.
        let requests = server.requests.lock().unwrap().clone();
        assert_eq!(requests.len(), 3);
        let mint_req = &requests[0];
        assert!(
            mint_req
                .to_lowercase()
                .starts_with("post /oauth/device/code http/1.1")
        );
        let mint_json: Value =
            serde_json::from_str(mint_req.split("\r\n\r\n").nth(1).unwrap()).unwrap();
        assert_eq!(mint_json["client_id"], "fvoc_fluxvale_cli");
        assert_eq!(mint_json["code_challenge_method"], "S256");
        let challenge = mint_json["code_challenge"].as_str().unwrap();
        assert_eq!(challenge.len(), 43);

        let poll_req = &requests[1];
        assert!(
            poll_req
                .to_lowercase()
                .starts_with("post /oauth/token http/1.1")
        );
        assert!(
            poll_req
                .to_lowercase()
                .contains("content-type: application/x-www-form-urlencoded")
        );
        let poll_body = poll_req.split("\r\n\r\n").nth(1).unwrap();
        assert_eq!(
            form_param(poll_body, "device_code").as_deref(),
            Some(SECRET_DEVICE_CODE)
        );
        let verifier = form_param(poll_body, "code_verifier").unwrap();
        assert_eq!(verifier.len(), 43);
        assert_eq!(pkce_challenge(&verifier), challenge);

        // Strict never-leaks assertions across banner, progress, confirmation, and Debug output.
        let printed = rec.joined();
        assert!(printed.contains("WXYZ-VKLM"));
        assert!(printed.contains("https://fluxvale.com/oauth/device?user_code=WXYZ-VKLM"));
        let debug_stored = format!("{stored:?}");
        for secret in [
            SECRET_ACCESS_TOKEN,
            SECRET_REFRESH_TOKEN,
            SECRET_DEVICE_CODE,
            verifier.as_str(),
        ] {
            assert!(!printed.contains(secret), "printed output leaked {secret}");
            assert!(
                !final_line.contains(secret),
                "confirmation line leaked {secret}"
            );
            assert!(
                !debug_stored.contains(secret),
                "Debug output leaked {secret}"
            );
        }
    }

    #[test]
    fn login_opens_page_by_default_and_survives_failed_launch() {
        for (launch_fails, include_complete) in [(false, true), (true, false)] {
            let server = script(vec![
                respond("200 OK", &mint_body("OPEN-CODE", include_complete)),
                respond("200 OK", &token_pair_body("instances:read")),
            ]);
            let dir = temp_dir();
            let rec = recorder();
            let opened = Arc::new(Mutex::new(None));
            let captured = opened.clone();
            let final_line = login(
                &server.base_url,
                "fluxvale.com",
                &McpLoginFlags {
                    scopes: None,
                    resource: None,
                    no_open: false,
                },
                file_save(&dir, "fluxvale.com"),
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
                || 1_700_000_000,
            )
            .unwrap();

            let expected_uri = if include_complete {
                "https://fluxvale.com/oauth/device?user_code=OPEN-CODE"
            } else {
                "https://fluxvale.com/oauth/device"
            };
            assert_eq!(opened.lock().unwrap().as_deref(), Some(expected_uri));
            if launch_fails {
                assert!(rec.joined().contains("no browser here"));
            }
            assert!(final_line.contains("signed in for MCP on fluxvale.com"));
        }
    }

    #[test]
    fn login_forwards_scopes_and_resource_and_maps_errors() {
        let server = script(vec![
            respond("200 OK", &mint_body("SCOP-RES1", true)),
            respond("200 OK", &token_pair_body("instances:read wallet:read")),
        ]);
        let dir = temp_dir();
        let rec = recorder();
        let final_line = login(
            &server.base_url,
            "staging.fluxvale.com",
            &McpLoginFlags {
                scopes: Some("instances:read, wallet:read".to_string()),
                resource: Some("https://mcp-staging.fluxvale.com/mcp".to_string()),
                no_open: true,
            },
            file_save(&dir, "staging.fluxvale.com"),
            |_| panic!("no_open must not launch"),
            rec.sleep(),
            rec.notify(),
            rec.notify(),
            || 1_700_000_000,
        )
        .unwrap();
        assert!(final_line.contains("staging.fluxvale.com"));

        let stored = FileMcpTokenStore::at(dir)
            .get("staging.fluxvale.com")
            .unwrap()
            .unwrap();
        assert_eq!(
            stored.resource.as_deref(),
            Some("https://mcp-staging.fluxvale.com/mcp")
        );

        let mint_req = &server.requests.lock().unwrap()[0];
        let mint_json: Value =
            serde_json::from_str(mint_req.split("\r\n\r\n").nth(1).unwrap()).unwrap();
        assert_eq!(mint_json["scope"], "instances:read wallet:read");
        assert_eq!(
            mint_json["resource"],
            "https://mcp-staging.fluxvale.com/mcp"
        );

        // Mint error does not leak anything and propagates server words.
        let err_server = script(vec![respond(
            "400 Bad Request",
            &json!({"error": "invalid_target", "error_description": "resource not allowed"}),
        )]);
        let rec2 = recorder();
        let err = login(
            &err_server.base_url,
            "fluxvale.com",
            &McpLoginFlags {
                scopes: None,
                resource: Some("https://bad.example/mcp".to_string()),
                no_open: true,
            },
            file_save(&temp_dir(), "fluxvale.com"),
            |_| Ok(()),
            rec2.sleep(),
            rec2.notify(),
            rec2.notify(),
            || 0,
        )
        .unwrap_err();
        assert_eq!(err.to_string(), "invalid_target: resource not allowed");
    }

    #[test]
    fn banner_boxes_code_and_names_uri() {
        let banner = mcp_login_banner("ABCD-EFGH", "https://fluxvale.com/oauth/device");
        assert!(banner.contains("https://fluxvale.com/oauth/device"));
        assert!(banner.contains("│  ABCD-EFGH  │"));
        assert!(!banner.contains('—'));
        assert!(!banner.contains(';'));
        let widths: Vec<usize> = banner
            .lines()
            .filter(|line| line.contains('┌') || line.contains('└') || line.contains('│'))
            .map(|line| line.chars().count())
            .collect();
        assert_eq!(widths.len(), 3);
        assert!(widths.windows(2).all(|w| w[0] == w[1]));
    }

    #[test]
    fn logout_removes_and_stays_honest_when_absent_or_stuck() {
        let dir = temp_dir();
        let store = FileMcpTokenStore::at(dir);
        let creds = McpCredentials {
            access_token: Token::new(SECRET_ACCESS_TOKEN),
            refresh_token: Token::new(SECRET_REFRESH_TOKEN),
            expires_at_unix: 1_700_003_600,
            scope: "instances:read".to_string(),
            resource: None,
        };
        store.set("fluxvale.com", &creds).unwrap();
        store.set("staging.fluxvale.com", &creds).unwrap();

        let line = logout(
            || store.get("fluxvale.com"),
            || store.remove("fluxvale.com"),
        )
        .unwrap();
        assert_eq!(line, "signed out of MCP, stored credentials were removed");
        assert!(!line.contains('—'));
        assert!(!line.contains(';'));
        assert!(store.get("fluxvale.com").unwrap().is_none());
        assert!(store.get("staging.fluxvale.com").unwrap().is_some());

        let again = logout(
            || store.get("fluxvale.com"),
            || store.remove("fluxvale.com"),
        )
        .unwrap();
        assert_eq!(again, "not signed in for MCP");

        let stuck = logout(|| Ok(Some(creds.clone())), || Ok(())).unwrap_err();
        assert_eq!(
            stuck.to_string(),
            "the stored MCP credentials could not be removed"
        );

        let cleared_after_corrupt = std::cell::Cell::new(false);
        let corrupt_line = logout(
            || {
                if cleared_after_corrupt.get() {
                    Ok(None)
                } else {
                    Err(anyhow::anyhow!("corrupt store"))
                }
            },
            || {
                cleared_after_corrupt.set(true);
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(
            corrupt_line,
            "signed out of MCP, stored credentials were removed"
        );
    }

    #[test]
    fn status_reports_absent_active_and_expired_without_leaking_tokens() {
        let absent = status("fluxvale.com", 1_700_000_000, || Ok(None)).unwrap();
        assert!(absent.contains("not signed in for MCP on fluxvale.com"));
        assert!(!absent.contains('—'));
        assert!(!absent.contains(';'));

        let creds = McpCredentials {
            access_token: Token::new(SECRET_ACCESS_TOKEN),
            refresh_token: Token::new(SECRET_REFRESH_TOKEN),
            expires_at_unix: 1_700_003_600,
            scope: "instances:read wallet:read".to_string(),
            resource: Some("https://mcp.fluxvale.com/mcp".to_string()),
        };

        let active = status("fluxvale.com", 1_700_000_000, || {
            Ok(Some((creds.clone(), TokenLocation::Keychain)))
        })
        .unwrap();
        assert!(active.contains("signed in for MCP on fluxvale.com via the OS keychain"));
        assert!(active.contains("scopes: instances:read wallet:read"));
        assert!(active.contains("resource: https://mcp.fluxvale.com/mcp"));
        assert!(active.contains("active (access token expires in 3600s)"));
        assert!(!active.contains(SECRET_ACCESS_TOKEN));
        assert!(!active.contains(SECRET_REFRESH_TOKEN));
        assert!(!active.contains('—'));
        assert!(!active.contains(';'));

        let expired = status("fluxvale.com", 1_700_003_720, || {
            Ok(Some((creds, TokenLocation::FallbackFile)))
        })
        .unwrap();
        assert!(expired.contains("via the MCP credentials file"));
        assert!(expired.contains("expired (120s ago, refresh token available)"));
        assert!(!expired.contains(SECRET_ACCESS_TOKEN));
        assert!(!expired.contains(SECRET_REFRESH_TOKEN));
    }

    fn temp_dir() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "fluxvale-cli-mcp-test-{}-{}",
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
