//! The PAT mint wire (`POST /api/v1/tokens`, #772): the CLI's
//! `auth token` asks an existing sign-in for a scoped, short-lived
//! credential a pipeline can carry. Plain JSON — the answer's
//! `access_token` is a one-time secret, so it lives in [`Token`] and
//! never prints through Debug.

use crate::token::Token;
use serde_json::{Value, json};
use std::fmt;
use std::time::Duration;

/// What `auth token` asks the server to mint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MintRequest {
    /// The token row's panel name; `None` lets the server default it.
    pub name: Option<String>,
    /// The scopes to grant. The server refuses any scope the caller
    /// does not already hold.
    pub scopes: Vec<String>,
    /// Requested lifetime; the server caps it at one year AND at the
    /// caller's own expiry.
    pub ttl_seconds: u64,
}

/// A minted token — the raw value rides [`Token`], so Debug and
/// Display redact it. `scopes`/`expires_at` are the server's effective
/// answer, not the request echoed.
#[derive(Clone, PartialEq, Eq)]
pub struct MintedToken {
    pub id: String,
    pub name: String,
    pub token: Token,
    pub scopes: Vec<String>,
    pub expires_at: String,
}

impl fmt::Debug for MintedToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MintedToken")
            .field("id", &self.id)
            .field("name", &self.name)
            .field("token", &self.token)
            .field("scopes", &self.scopes)
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

/// A client for the authenticated plain-JSON mint route.
pub struct TokenClient {
    agent: ureq::Agent,
    base_url: String,
    token: Token,
}

impl TokenClient {
    pub fn new(base_url: &str, token: Token) -> Self {
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(30)))
            .build()
            .into();
        TokenClient {
            agent,
            base_url: base_url.trim_end_matches('/').to_string(),
            token,
        }
    }

    /// `POST /api/v1/tokens` — mint one scoped token. The caller's
    /// token rides the Authorization header; the raw answer never
    /// appears in an error or a Debug form.
    pub fn mint(&self, request: &MintRequest) -> anyhow::Result<MintedToken> {
        // The caller PAT and the minted value both cross this wire:
        // refuse a cleartext remote origin before either is sent.
        if !is_https_or_loopback(&self.base_url) {
            anyhow::bail!(
                "the base URL must use https:// (http:// is allowed only for a loopback host)"
            );
        }

        let mut body = json!({
            "scopes": request.scopes,
            "ttl_seconds": request.ttl_seconds,
        });
        if let Some(name) = &request.name {
            body["name"] = json!(name);
        }

        let url = format!("{}/api/v1/tokens", self.base_url);
        let mut response = self
            .agent
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.token.expose()))
            .header("Content-Type", "application/json")
            .header("Accept", "application/json")
            .send(body.to_string().into_bytes())
            .map_err(|err| anyhow::anyhow!("connection failed: {err}"))?;

        let status = response.status().as_u16();
        let raw = response
            .body_mut()
            .read_to_string()
            .map_err(|err| anyhow::anyhow!("connection failed: {err}"))?;
        let body: Value = serde_json::from_str(&raw)
            .map_err(|err| anyhow::anyhow!("HTTP {status}: unreadable body ({err})"))?;

        if !(200..300).contains(&status) {
            return Err(server_error(status, &body));
        }

        let scope = string_field(&body, "scope")?;
        Ok(MintedToken {
            id: string_field(&body, "id")?,
            name: string_field(&body, "name")?,
            token: Token::new(string_field(&body, "access_token")?),
            scopes: scope.split_whitespace().map(str::to_owned).collect(),
            expires_at: string_field(&body, "expires_at")?,
        })
    }
}

/// HTTPS for any host; HTTP only when the host is loopback. A remote
/// `http://` base URL would put the caller token and the minted value
/// on the network in cleartext.
fn is_https_or_loopback(base_url: &str) -> bool {
    let lower = base_url.trim_end_matches('/').to_ascii_lowercase();
    if lower.starts_with("https://") {
        return true;
    }
    let Some(rest) = lower.strip_prefix("http://") else {
        return false;
    };
    // Drop userinfo, then the path/query; bracketed IPv6 keeps its
    // closing bracket.
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host_port = authority.rsplit('@').next().unwrap_or(authority);
    let host = if host_port.starts_with('[') {
        match host_port.split_once(']') {
            // The bracketed host must end there or continue straight
            // into a port — `[::1].evil.test` is not loopback.
            Some((host, rest)) if rest.is_empty() || rest.starts_with(':') => format!("{host}]"),
            _ => String::new(),
        }
    } else {
        host_port.split(':').next().unwrap_or("").to_string()
    };
    matches!(host.as_str(), "127.0.0.1" | "localhost" | "[::1]")
}

fn string_field(body: &Value, field: &str) -> anyhow::Result<String> {
    body.get(field)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| anyhow::anyhow!("the answer carries no {field}"))
}

/// The server's own words. The mint route answers JSON:API error
/// documents; the OAuth-shaped fallbacks keep a proxy/older-server
/// answer intelligible.
fn server_error(status: u16, body: &Value) -> anyhow::Error {
    let detail = body
        .pointer("/errors/0/detail")
        .and_then(Value::as_str)
        .or_else(|| body.get("error_description").and_then(Value::as_str))
        .or_else(|| body.get("error").and_then(Value::as_str));

    match detail {
        Some(detail) => anyhow::anyhow!("{detail}"),
        None => anyhow::anyhow!("HTTP {status}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::io::{Read as _, Write as _};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

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

    fn captured(server: &Script) -> Vec<String> {
        server
            .requests
            .lock()
            .unwrap()
            .iter()
            .map(|raw| raw.to_lowercase())
            .collect()
    }

    fn minted_body() -> serde_json::Value {
        json!({
            "id": "01JTOKEN",
            "name": "ci-terraform",
            "access_token": "fvpat_minted_value",
            "token_type": "Bearer",
            "scope": "instances:read backups:read",
            "expires_at": "2026-11-13T23:30:00Z"
        })
    }

    #[test]
    fn mint_sends_the_caller_token_and_parses_the_answer() {
        let server = script(vec![respond("201 Created", &minted_body())]);
        let minted = TokenClient::new(&server.base_url, Token::new("fvpat_caller"))
            .mint(&MintRequest {
                name: Some("ci-terraform".to_string()),
                scopes: vec!["instances:read".to_string(), "backups:read".to_string()],
                ttl_seconds: 3600,
            })
            .unwrap();

        assert_eq!(minted.id, "01JTOKEN");
        assert_eq!(minted.name, "ci-terraform");
        assert_eq!(minted.token, Token::new("fvpat_minted_value"));
        assert_eq!(minted.scopes, vec!["instances:read", "backups:read"]);
        assert_eq!(minted.expires_at, "2026-11-13T23:30:00Z");

        let head = captured(&server).remove(0);
        assert!(
            head.starts_with("post /api/v1/tokens http/1.1"),
            "head: {head}"
        );
        assert!(
            head.contains("authorization: bearer fvpat_caller"),
            "head: {head}"
        );
        assert!(
            head.contains("content-type: application/json"),
            "head: {head}"
        );
        assert!(
            head.contains("\"scopes\":[\"instances:read\",\"backups:read\"]"),
            "head: {head}"
        );
        assert!(head.contains("\"ttl_seconds\":3600"), "head: {head}");
        assert!(head.contains("\"name\":\"ci-terraform\""), "head: {head}");
        // The caller's token is the only credential on the wire.
        assert!(!head.contains("fvpat_minted_value"), "head: {head}");
    }

    #[test]
    fn a_remote_cleartext_origin_is_refused_before_the_pat_is_sent() {
        let err = TokenClient::new("http://example.com", Token::new("fvpat_caller"))
            .mint(&MintRequest {
                name: None,
                scopes: vec![],
                ttl_seconds: 60,
            })
            .unwrap_err();
        assert!(err.to_string().contains("https://"), "err: {err}");
    }

    #[test]
    fn the_origin_rule_allows_https_and_loopback_http_only() {
        for allowed in [
            "https://staging.fluxvale.com",
            "https://fluxvale.com/",
            "http://localhost:4123",
            "http://127.0.0.1:1",
            "http://[::1]:4000",
        ] {
            assert!(is_https_or_loopback(allowed), "{allowed} must pass");
        }

        for refused in [
            "http://example.com",
            "http://127.0.0.1.evil.test",
            "http://user@evil.test",
            "http://[::1].evil.test",
            "ftp://fluxvale.com",
            "fluxvale.com",
        ] {
            assert!(!is_https_or_loopback(refused), "{refused} must refuse");
        }
    }

    #[test]
    fn a_nameless_mint_omits_the_name_field() {
        let server = script(vec![respond("201 Created", &minted_body())]);
        TokenClient::new(&server.base_url, Token::new("fvpat_caller"))
            .mint(&MintRequest {
                name: None,
                scopes: vec![],
                ttl_seconds: 60,
            })
            .unwrap();

        let head = captured(&server).remove(0);
        assert!(!head.contains("\"name\""), "head: {head}");
    }

    #[test]
    fn refusals_carry_the_server_words() {
        let server = script(vec![respond(
            "403 Forbidden",
            &json!({"errors": [{"status": "403", "title": "Forbidden",
                "detail": "the caller's token does not grant scope instances:write"}]}),
        )]);

        let err = TokenClient::new(&server.base_url, Token::new("fvpat_caller"))
            .mint(&MintRequest {
                name: None,
                scopes: vec!["instances:write".to_string()],
                ttl_seconds: 60,
            })
            .unwrap_err();

        assert!(
            err.to_string()
                .contains("does not grant scope instances:write"),
            "err: {err}"
        );
    }

    #[test]
    fn the_oauth_shaped_fallbacks_surface_the_server_words() {
        for body in [
            json!({"error": "invalid_client", "error_description": "unknown client"}),
            json!({"error": "invalid_scope"}),
        ] {
            let server = script(vec![respond("400 Bad Request", &body)]);
            let err = TokenClient::new(&server.base_url, Token::new("fvpat_caller"))
                .mint(&MintRequest {
                    name: None,
                    scopes: vec![],
                    ttl_seconds: 60,
                })
                .unwrap_err();
            let text = err.to_string();
            assert!(
                text.starts_with("unknown client") || text == "invalid_scope",
                "err: {text}"
            );
        }
    }

    #[test]
    fn a_bare_error_body_still_names_the_status() {
        let server = script(vec![respond("502 Bad Gateway", &json!({}))]);
        let err = TokenClient::new(&server.base_url, Token::new("fvpat_caller"))
            .mint(&MintRequest {
                name: None,
                scopes: vec![],
                ttl_seconds: 60,
            })
            .unwrap_err();
        assert_eq!(err.to_string(), "HTTP 502");
    }

    #[test]
    fn a_missing_field_is_an_error_not_a_panic() {
        let mut body = minted_body();
        body.as_object_mut().unwrap().remove("access_token");
        let server = script(vec![respond("201 Created", &body)]);
        let err = TokenClient::new(&server.base_url, Token::new("fvpat_caller"))
            .mint(&MintRequest {
                name: None,
                scopes: vec![],
                ttl_seconds: 60,
            })
            .unwrap_err();
        assert!(err.to_string().contains("access_token"), "err: {err}");
    }

    #[test]
    fn debug_redacts_the_minted_value() {
        let minted = MintedToken {
            id: "01JTOKEN".to_string(),
            name: "ci".to_string(),
            token: Token::new("fvpat_minted_value"),
            scopes: vec![],
            expires_at: "2026-11-13T23:30:00Z".to_string(),
        };
        let debug = format!("{minted:?}");
        assert!(!debug.contains("fvpat_minted_value"), "debug: {debug}");
        assert!(debug.contains("Token(***redacted***)"), "debug: {debug}");
    }
}
