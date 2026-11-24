//! OAuth 2.0 device authorization grant with PKCE (RFC 8628 + ADR-0054 Am. 1):
//! mint a device grant at `/oauth/device/code` with an S256 code challenge,
//! poll `/oauth/token` with form-encoded `code_verifier`, and refresh token
//! pairs via `refresh_token`.
//!
//! Secrets (`PkceVerifier`, `device_code`, `access_token`, `refresh_token`)
//! are redacted in `Debug` output. Sleeping and progress notifications stay
//! caller-side in [`oauth_poll_loop`].

use crate::token::Token;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ring::digest::{SHA256, digest};
use ring::rand::{SecureRandom as _, SystemRandom};
use serde_json::{Map, Value};
use std::fmt;
use std::time::Duration;

/// Seeded first-party public client for the CLI MCP OAuth flow.
pub const OAUTH_CLI_CLIENT_ID: &str = "fvoc_fluxvale_cli";

/// RFC 8628 §3.5 device code grant type.
pub const OAUTH_DEVICE_GRANT_TYPE: &str = "urn:ietf:params:oauth:grant-type:device_code";

/// RFC 8628 §3.5: after `slow_down`, every subsequent poll waits this many seconds longer.
const SLOW_DOWN_PENALTY_SECS: u64 = 5;

/// Default poll interval in seconds when omitted by the server (RFC 8628 §3.2).
const DEFAULT_POLL_INTERVAL_SECS: u64 = 5;

/// Consecutive transient poll errors (connection, 429, or 5xx) tolerated before aborting.
const MAX_CONSECUTIVE_TRANSIENT_ERRORS: usize = 3;

/// A high-entropy PKCE code verifier (RFC 7636 §4.1): 32 CSPRNG bytes
/// base64url-encoded without padding (43 unreserved characters).
#[derive(Clone, PartialEq, Eq)]
pub struct PkceVerifier(String);

impl PkceVerifier {
    /// Generate a fresh 32-byte CSPRNG PKCE verifier.
    pub fn generate() -> Self {
        let rng = SystemRandom::new();
        let mut bytes = [0u8; 32];
        rng.fill(&mut bytes)
            .expect("system CSPRNG failed to generate PKCE verifier");
        PkceVerifier(URL_SAFE_NO_PAD.encode(bytes))
    }

    /// Expose the raw verifier for the `/oauth/token` exchange only.
    pub fn expose(&self) -> &str {
        &self.0
    }

    /// Compute the RFC 7636 `S256` challenge: `BASE64URL(SHA256(ASCII(verifier)))`.
    pub fn challenge(&self) -> String {
        pkce_challenge(&self.0)
    }
}

/// Compute the RFC 7636 `S256` challenge for an ASCII PKCE code verifier.
pub fn pkce_challenge(verifier: &str) -> String {
    let hash = digest(&SHA256, verifier.as_bytes());
    URL_SAFE_NO_PAD.encode(hash.as_ref())
}

impl fmt::Debug for PkceVerifier {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("PkceVerifier(***redacted***)")
    }
}

/// The RFC 8628 §3.2 device authorization response.
#[derive(Clone, PartialEq, Eq)]
pub struct OAuthDeviceMinted {
    /// The poll capability, never printed.
    pub device_code: String,
    /// The human-facing comparison code.
    pub user_code: String,
    pub verification_uri: String,
    pub verification_uri_complete: Option<String>,
    /// Seconds between counted polls.
    pub interval: u64,
}

impl fmt::Debug for OAuthDeviceMinted {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("OAuthDeviceMinted")
            .field("device_code", &"***redacted***")
            .field("user_code", &self.user_code)
            .field("verification_uri", &self.verification_uri)
            .field("verification_uri_complete", &self.verification_uri_complete)
            .field("interval", &self.interval)
            .finish()
    }
}

/// An OAuth token pair returned by `/oauth/token`.
#[derive(Clone, PartialEq, Eq)]
pub struct OAuthTokenPair {
    pub access_token: Token,
    pub refresh_token: Token,
    pub expires_in: u64,
    pub scope: String,
}

impl fmt::Debug for OAuthTokenPair {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("OAuthTokenPair")
            .field("access_token", &"***redacted***")
            .field("refresh_token", &"***redacted***")
            .field("expires_in", &self.expires_in)
            .field("scope", &self.scope)
            .finish()
    }
}

/// Why a refresh failed. A [`RefreshError::Transient`] failure leaves the
/// stored pair good: the token endpoint was not itself for a moment, and a
/// later attempt may succeed. A [`RefreshError::Permanent`] one means no
/// later attempt can.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefreshError {
    /// The token endpoint could not be reached, was unavailable, or answered oddly. The stored pair is untouched and a later attempt may succeed.
    Transient(String),
    /// A later attempt cannot succeed: the token endpoint refused the refresh token, or the request cannot be made at all.
    Permanent(String),
}

impl RefreshError {
    fn transient(text: impl Into<String>) -> Self {
        RefreshError::Transient(text.into())
    }

    fn permanent(text: impl Into<String>) -> Self {
        RefreshError::Permanent(text.into())
    }
}

impl fmt::Display for RefreshError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let (RefreshError::Transient(text) | RefreshError::Permanent(text)) = self;
        f.write_str(text)
    }
}

impl std::error::Error for RefreshError {}

/// One poll answer from `/oauth/token` (RFC 8628 §3.5).
#[derive(Debug)]
pub enum OAuthPoll {
    /// Authorization is still pending.
    Pending,
    /// Back off an extra 5 seconds before the next poll.
    SlowDown,
    /// The user denied authorization.
    Denied,
    /// The device code expired or was already consumed.
    Expired,
    /// The one-time grant carrying the access and refresh tokens.
    Granted(OAuthTokenPair),
}

/// Client for the OAuth device authorization and token endpoints.
pub struct OAuthDeviceClient {
    agent: ureq::Agent,
    base_url: String,
}

impl OAuthDeviceClient {
    pub fn new(base_url: &str) -> Self {
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(30)))
            .build()
            .into();
        OAuthDeviceClient {
            agent,
            base_url: base_url.trim_end_matches('/').to_string(),
        }
    }

    fn post_json(&self, path: &str, body: &Value) -> anyhow::Result<(u16, Value)> {
        crate::tokens::require_https_or_loopback(&self.base_url)?;
        let url = format!("{}{}", self.base_url, path);
        let response = self
            .agent
            .post(&url)
            .header("Content-Type", "application/json")
            .send(body.to_string().into_bytes())
            .map_err(|err| anyhow::anyhow!("connection failed: {err}"))?;
        read_json_response(response)
    }

    /// `POST /oauth/device/code` with JSON body including PKCE S256 challenge.
    pub fn mint(
        &self,
        scopes: &[String],
        resource: Option<&str>,
        code_challenge: &str,
    ) -> anyhow::Result<OAuthDeviceMinted> {
        let mut map = Map::new();
        map.insert(
            "client_id".to_string(),
            Value::String(OAUTH_CLI_CLIENT_ID.to_string()),
        );
        map.insert(
            "code_challenge".to_string(),
            Value::String(code_challenge.to_string()),
        );
        map.insert(
            "code_challenge_method".to_string(),
            Value::String("S256".to_string()),
        );
        if !scopes.is_empty() {
            map.insert("scope".to_string(), Value::String(scopes.join(" ")));
        }
        if let Some(resource) = resource {
            map.insert("resource".to_string(), Value::String(resource.to_string()));
        }

        let (status, body) = self.post_json("/oauth/device/code", &Value::Object(map))?;
        if status != 200 {
            return Err(oauth_error(status, &body));
        }

        Ok(OAuthDeviceMinted {
            device_code: string_field(&body, "device_code")?,
            user_code: string_field(&body, "user_code")?,
            verification_uri: string_field(&body, "verification_uri")?,
            verification_uri_complete: body
                .get("verification_uri_complete")
                .and_then(Value::as_str)
                .map(str::to_owned),
            interval: body
                .get("interval")
                .and_then(Value::as_u64)
                .unwrap_or(DEFAULT_POLL_INTERVAL_SECS),
        })
    }

    /// `POST /oauth/token` for `device_code` grant with `code_verifier`.
    pub fn poll(&self, device_code: &str, code_verifier: &str) -> anyhow::Result<OAuthPoll> {
        match self.poll_step(device_code, code_verifier) {
            PollStep::Answer(answer) => Ok(answer),
            PollStep::Transient(err) | PollStep::Fatal(err) => Err(err),
        }
    }

    fn poll_step(&self, device_code: &str, code_verifier: &str) -> PollStep {
        if let Err(err) = crate::tokens::require_https_or_loopback(&self.base_url) {
            return PollStep::Fatal(err);
        }

        let url = format!("{}/oauth/token", self.base_url);
        let encoded = encode_form(&[
            ("grant_type", OAUTH_DEVICE_GRANT_TYPE),
            ("client_id", OAUTH_CLI_CLIENT_ID),
            ("device_code", device_code),
            ("code_verifier", code_verifier),
        ]);
        let mut response = match self
            .agent
            .post(&url)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .send(encoded.into_bytes())
        {
            Ok(resp) => resp,
            Err(err) => return PollStep::Transient(anyhow::anyhow!("connection failed: {err}")),
        };

        let status = response.status().as_u16();
        let raw = match response.body_mut().read_to_string() {
            Ok(raw) => raw,
            Err(err) => return PollStep::Transient(anyhow::anyhow!("connection failed: {err}")),
        };
        let parsed = serde_json::from_str::<Value>(&raw);

        if status == 429 || status >= 500 {
            let err = match parsed {
                Ok(body) => oauth_error(status, &body),
                Err(_) => anyhow::anyhow!("HTTP {status}"),
            };
            return PollStep::Transient(err);
        }

        let body = match parsed {
            Ok(body) => body,
            Err(err) => {
                return PollStep::Fatal(anyhow::anyhow!("HTTP {status}: unreadable body ({err})"));
            }
        };

        if status == 200 {
            return match parse_token_pair(&body) {
                Ok(pair) => PollStep::Answer(OAuthPoll::Granted(pair)),
                Err(err) => PollStep::Fatal(err),
            };
        }

        match body.get("error").and_then(Value::as_str) {
            Some("authorization_pending") => PollStep::Answer(OAuthPoll::Pending),
            Some("slow_down") => PollStep::Answer(OAuthPoll::SlowDown),
            Some("access_denied") => PollStep::Answer(OAuthPoll::Denied),
            Some("expired_token") => PollStep::Answer(OAuthPoll::Expired),
            _ => PollStep::Fatal(oauth_error(status, &body)),
        }
    }

    /// `POST /oauth/token` for `refresh_token` grant. The failure says
    /// whether a later attempt can succeed.
    ///
    /// A refresh token the endpoint refused is refused for good, and so is
    /// any other status that means no: [`RefreshError::Permanent`]. A 408,
    /// a 429 and a 5xx refuse nothing, and neither does an endpoint that
    /// could not be reached, that answered before the whole body arrived,
    /// or that answered 200 with something that is not a token pair: those
    /// are [`RefreshError::Transient`], and the stored pair is untouched.
    /// A request that cannot be built at all, a proxy URL or a TLS setting
    /// this process got wrong, is `Permanent` too, since no retry changes
    /// this process's configuration ([`transport_failure`]).
    pub fn refresh(
        &self,
        refresh_token: &Token,
        resource: Option<&str>,
    ) -> Result<OAuthTokenPair, RefreshError> {
        // The refresh token is on the wire below: a cleartext remote
        // origin is refused before it is sent.
        crate::tokens::require_https_or_loopback(&self.base_url)
            .map_err(|err| RefreshError::permanent(err.to_string()))?;
        let mut pairs = vec![
            ("grant_type", "refresh_token"),
            ("client_id", OAUTH_CLI_CLIENT_ID),
            ("refresh_token", refresh_token.expose()),
        ];
        if let Some(resource) = resource {
            pairs.push(("resource", resource));
        }

        let url = format!("{}/oauth/token", self.base_url);
        let encoded = encode_form(&pairs);
        let mut response = self
            .agent
            .post(&url)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .send(encoded.into_bytes())
            .map_err(transport_failure)?;
        let status = response.status().as_u16();
        let raw = response
            .body_mut()
            .read_to_string()
            .map_err(|err| RefreshError::transient(format!("connection failed: {err}")))?;

        // A 408, a 429 and a 5xx refuse nothing: the endpoint is having a
        // bad moment, and so is one that answers 200 with something that
        // is not a token pair. Any later attempt may succeed.
        let refuses_nothing = status == 200 || status == 408 || status == 429 || status >= 500;
        let classified = |text: String| {
            if refuses_nothing {
                RefreshError::transient(text)
            } else {
                RefreshError::permanent(text)
            }
        };
        match serde_json::from_str::<Value>(&raw) {
            Ok(body) if status == 200 => {
                parse_token_pair(&body).map_err(|err| RefreshError::transient(err.to_string()))
            }
            Ok(body) => Err(classified(oauth_error(status, &body).to_string())),
            Err(err) => Err(classified(format!(
                "HTTP {status}: unreadable body ({err})"
            ))),
        }
    }
}

/// Why a request that never got its answer failed. Some of ureq's errors
/// come from this process's own configuration, a proxy URL or a TLS
/// setting that cannot be right, and no retry changes those: those are
/// [`RefreshError::Permanent`]. Every other one is the network, or the
/// endpoint, having a bad moment.
fn transport_failure(err: ureq::Error) -> RefreshError {
    let from_configuration = matches!(
        err,
        ureq::Error::BadUri(_)
            | ureq::Error::InvalidProxyUrl
            | ureq::Error::Http(_)
            | ureq::Error::RequireHttpsOnly(_)
            | ureq::Error::TlsRequired
    );
    if from_configuration {
        RefreshError::permanent(format!("the token request cannot be made: {err}"))
    } else {
        RefreshError::transient(format!("connection failed: {err}"))
    }
}

fn read_json_response(
    mut response: ureq::http::Response<ureq::Body>,
) -> anyhow::Result<(u16, Value)> {
    let status = response.status().as_u16();
    let raw = response
        .body_mut()
        .read_to_string()
        .map_err(|err| anyhow::anyhow!("connection failed: {err}"))?;
    let body = serde_json::from_str(&raw)
        .map_err(|err| anyhow::anyhow!("HTTP {status}: unreadable body ({err})"))?;
    Ok((status, body))
}

fn parse_token_pair(body: &Value) -> anyhow::Result<OAuthTokenPair> {
    Ok(OAuthTokenPair {
        access_token: Token::new(string_field(body, "access_token")?),
        refresh_token: Token::new(string_field(body, "refresh_token")?),
        expires_in: body
            .get("expires_in")
            .and_then(Value::as_u64)
            .ok_or_else(|| anyhow::anyhow!("the token answer carries no expires_in"))?,
        scope: body
            .get("scope")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned(),
    })
}

fn string_field(body: &Value, field: &str) -> anyhow::Result<String> {
    body.get(field)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| anyhow::anyhow!("the answer carries no {field}"))
}

fn oauth_error(status: u16, body: &Value) -> anyhow::Error {
    let code = body.get("error").and_then(Value::as_str).unwrap_or("");
    let description = body.get("error_description").and_then(Value::as_str);
    match (code, description) {
        ("", _) => anyhow::anyhow!("HTTP {status}"),
        (code, Some(description)) => anyhow::anyhow!("{code}: {description}"),
        (code, None) => anyhow::anyhow!("HTTP {status}: {code}"),
    }
}

fn encode_form(pairs: &[(&str, &str)]) -> String {
    pairs
        .iter()
        .map(|(k, v)| format!("{}={}", percent_encode(k), percent_encode(v)))
        .collect::<Vec<_>>()
        .join("&")
}

fn percent_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for byte in input.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char);
            }
            other => {
                out.push('%');
                out.push(hex_upper(other >> 4));
                out.push(hex_upper(other & 0x0f));
            }
        }
    }
    out
}

fn hex_upper(nibble: u8) -> char {
    match nibble {
        0..=9 => (b'0' + nibble) as char,
        10..=15 => (b'A' + (nibble - 10)) as char,
        _ => unreachable!(),
    }
}

enum PollStep {
    Answer(OAuthPoll),
    Transient(anyhow::Error),
    Fatal(anyhow::Error),
}

/// Poll `/oauth/token` per RFC 8628 §3.5 until granted, denied, expired, or errored.
/// Clamps zero intervals to 1s, adds 5s on `slow_down`, tolerates up to 3 consecutive
/// transient errors (connection, 429, or 5xx), prints progress dots via `notify`, and
/// sleeps via the injected `sleep` closure.
pub fn oauth_poll_loop(
    client: &OAuthDeviceClient,
    device_code: &str,
    code_verifier: &str,
    interval_secs: u64,
    sleep: impl Fn(Duration),
    notify: impl Fn(&str),
) -> anyhow::Result<OAuthTokenPair> {
    let mut interval = interval_secs.max(1);
    let mut dots = 0usize;
    let mut consecutive_transient = 0usize;
    let pair = loop {
        match client.poll_step(device_code, code_verifier) {
            PollStep::Answer(answer) => {
                consecutive_transient = 0;
                match answer {
                    OAuthPoll::Pending => {
                        notify(".");
                        dots += 1;
                        sleep(Duration::from_secs(interval));
                    }
                    OAuthPoll::SlowDown => {
                        interval = interval.saturating_add(SLOW_DOWN_PENALTY_SECS);
                        notify(".");
                        dots += 1;
                        sleep(Duration::from_secs(interval));
                    }
                    OAuthPoll::Denied => anyhow::bail!("sign-in was denied"),
                    OAuthPoll::Expired => {
                        anyhow::bail!("the code expired, run `fluxvale mcp login` again")
                    }
                    OAuthPoll::Granted(pair) => break pair,
                }
            }
            PollStep::Transient(err) => {
                consecutive_transient += 1;
                if consecutive_transient > MAX_CONSECUTIVE_TRANSIENT_ERRORS {
                    return Err(err);
                }
                notify(".");
                dots += 1;
                sleep(Duration::from_secs(interval));
            }
            PollStep::Fatal(err) => return Err(err),
        }
    };
    if dots > 0 {
        notify("\n");
    }
    Ok(pair)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::VecDeque;
    use std::io::{Read as _, Write as _};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    fn mint_body(user_code: &str) -> Value {
        json!({
            "device_code": "dc_secret_device_code_value_0123456789abcdef",
            "user_code": user_code,
            "verification_uri": "https://fluxvale.com/oauth/device",
            "verification_uri_complete": format!("https://fluxvale.com/oauth/device?user_code={user_code}"),
            "expires_in": 600,
            "interval": 5
        })
    }

    fn token_pair_body() -> Value {
        json!({
            "access_token": "fvoat_raw_access_token_value",
            "refresh_token": "fvort_raw_refresh_token_value",
            "token_type": "Bearer",
            "expires_in": 3600,
            "scope": "instances:read wallet:read"
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

    fn captured_requests(server: &Script) -> Vec<String> {
        server.requests.lock().unwrap().clone()
    }

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

        fn joined(&self) -> String {
            self.fragments.lock().unwrap().join("")
        }
    }

    #[test]
    fn pkce_s256_matches_rfc_7636_appendix_b_vector_and_generates_43_chars() {
        // RFC 7636 Appendix B test vector.
        let verifier = PkceVerifier("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk".to_string());
        assert_eq!(
            verifier.challenge(),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
        assert_eq!(
            verifier.expose(),
            "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        );

        let generated = PkceVerifier::generate();
        assert_eq!(generated.expose().len(), 43);
        assert_eq!(generated.challenge().len(), 43);
        assert!(
            generated
                .expose()
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        );
        assert_ne!(generated.expose(), PkceVerifier::generate().expose());
    }

    #[test]
    fn debug_redacts_all_oauth_secrets() {
        let verifier = PkceVerifier("secret_pkce_verifier_value".to_string());
        let verifier_dbg = format!("{verifier:?}");
        assert!(!verifier_dbg.contains("secret_pkce_verifier_value"));
        assert!(verifier_dbg.contains("redacted"));

        let minted = OAuthDeviceMinted {
            device_code: "dc_secret_code_never_logged".to_string(),
            user_code: "ABCD-EFGH".to_string(),
            verification_uri: "https://fluxvale.com/oauth/device".to_string(),
            verification_uri_complete: Some(
                "https://fluxvale.com/oauth/device?user_code=ABCD-EFGH".to_string(),
            ),
            interval: 5,
        };
        let minted_dbg = format!("{minted:?}");
        assert!(!minted_dbg.contains("dc_secret_code_never_logged"));
        assert!(minted_dbg.contains("ABCD-EFGH"));

        let pair = OAuthTokenPair {
            access_token: Token::new("fvoat_secret_access"),
            refresh_token: Token::new("fvort_secret_refresh"),
            expires_in: 3600,
            scope: "instances:read".to_string(),
        };
        let pair_dbg = format!("{pair:?}");
        assert!(!pair_dbg.contains("fvoat_secret_access"));
        assert!(!pair_dbg.contains("fvort_secret_refresh"));
        assert!(pair_dbg.contains("instances:read"));

        let poll = OAuthPoll::Granted(pair);
        let poll_dbg = format!("{poll:?}");
        assert!(!poll_dbg.contains("fvoat_secret_access"));
        assert!(!poll_dbg.contains("fvort_secret_refresh"));
    }

    #[test]
    fn mint_sends_json_with_and_without_resource_and_parses_response() {
        let server = script(vec![
            respond("200 OK", &mint_body("ABCD-EFGH")),
            respond(
                "200 OK",
                &json!({
                    "device_code": "dc_two",
                    "user_code": "WXYZ-JKLM",
                    "verification_uri": "https://fluxvale.com/oauth/device",
                    "interval": 7
                }),
            ),
        ]);
        let client = OAuthDeviceClient::new(&server.base_url);

        let with_resource = client
            .mint(
                &["instances:read".to_string(), "wallet:read".to_string()],
                Some("https://mcp.fluxvale.com/mcp"),
                "challenge_1",
            )
            .unwrap();
        assert_eq!(with_resource.user_code, "ABCD-EFGH");
        assert_eq!(
            with_resource.verification_uri_complete.as_deref(),
            Some("https://fluxvale.com/oauth/device?user_code=ABCD-EFGH")
        );
        assert_eq!(with_resource.interval, 5);

        let without_resource = client.mint(&[], None, "challenge_2").unwrap();
        assert_eq!(without_resource.user_code, "WXYZ-JKLM");
        assert_eq!(without_resource.verification_uri_complete, None);
        assert_eq!(without_resource.interval, 7);

        let requests = captured_requests(&server);
        let first_lower = requests[0].to_lowercase();
        assert!(first_lower.starts_with("post /oauth/device/code http/1.1"));
        assert!(first_lower.contains("content-type: application/json"));
        let first_body: Value =
            serde_json::from_str(requests[0].split("\r\n\r\n").nth(1).unwrap()).unwrap();
        assert_eq!(first_body["client_id"], OAUTH_CLI_CLIENT_ID);
        assert_eq!(first_body["scope"], "instances:read wallet:read");
        assert_eq!(first_body["resource"], "https://mcp.fluxvale.com/mcp");
        assert_eq!(first_body["code_challenge"], "challenge_1");
        assert_eq!(first_body["code_challenge_method"], "S256");

        let second_body: Value =
            serde_json::from_str(requests[1].split("\r\n\r\n").nth(1).unwrap()).unwrap();
        assert!(second_body.get("scope").is_none());
        assert!(second_body.get("resource").is_none());
        assert_eq!(second_body["code_challenge"], "challenge_2");
    }

    #[test]
    fn mint_maps_oauth_error_envelope() {
        let server = script(vec![respond(
            "400 Bad Request",
            &json!({"error": "invalid_target", "error_description": "resource not allowed"}),
        )]);
        let err = OAuthDeviceClient::new(&server.base_url)
            .mint(
                &["instances:read".to_string()],
                Some("https://evil.example"),
                "c",
            )
            .unwrap_err();
        assert_eq!(err.to_string(), "invalid_target: resource not allowed");
    }

    #[test]
    fn poll_sends_form_encoded_request_and_maps_all_outcomes() {
        let server = script(vec![
            respond(
                "400 Bad Request",
                &json!({"error": "authorization_pending"}),
            ),
            respond("400 Bad Request", &json!({"error": "slow_down"})),
            respond("400 Bad Request", &json!({"error": "access_denied"})),
            respond("400 Bad Request", &json!({"error": "expired_token"})),
            respond("200 OK", &token_pair_body()),
        ]);
        let client = OAuthDeviceClient::new(&server.base_url);

        assert!(matches!(
            client.poll("dc+1", "ver/1").unwrap(),
            OAuthPoll::Pending
        ));
        assert!(matches!(
            client.poll("dc", "ver").unwrap(),
            OAuthPoll::SlowDown
        ));
        assert!(matches!(
            client.poll("dc", "ver").unwrap(),
            OAuthPoll::Denied
        ));
        assert!(matches!(
            client.poll("dc", "ver").unwrap(),
            OAuthPoll::Expired
        ));

        let granted = client.poll("dc", "ver").unwrap();
        let OAuthPoll::Granted(pair) = granted else {
            panic!("expected granted");
        };
        assert_eq!(
            pair.access_token,
            Token::new("fvoat_raw_access_token_value")
        );
        assert_eq!(
            pair.refresh_token,
            Token::new("fvort_raw_refresh_token_value")
        );
        assert_eq!(pair.expires_in, 3600);
        assert_eq!(pair.scope, "instances:read wallet:read");

        let requests = captured_requests(&server);
        let first_lower = requests[0].to_lowercase();
        assert!(first_lower.starts_with("post /oauth/token http/1.1"));
        assert!(first_lower.contains("content-type: application/x-www-form-urlencoded"));
        let first_body = requests[0].split("\r\n\r\n").nth(1).unwrap();
        assert_eq!(
            first_body,
            "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&client_id=fvoc_fluxvale_cli&device_code=dc%2B1&code_verifier=ver%2F1"
        );
    }

    #[test]
    fn poll_unknown_error_surfaces_server_words() {
        let server = script(vec![respond(
            "400 Bad Request",
            &json!({"error": "invalid_grant", "error_description": "code_verifier does not match"}),
        )]);
        let err = OAuthDeviceClient::new(&server.base_url)
            .poll("dc", "wrong")
            .unwrap_err();
        assert_eq!(
            err.to_string(),
            "invalid_grant: code_verifier does not match"
        );
    }

    #[test]
    fn refresh_sends_form_encoded_request_with_optional_resource() {
        let server = script(vec![
            respond("200 OK", &token_pair_body()),
            respond(
                "400 Bad Request",
                &json!({"error": "invalid_grant", "error_description": "refresh token revoked"}),
            ),
        ]);
        let client = OAuthDeviceClient::new(&server.base_url);

        let pair = client
            .refresh(
                &Token::new("fvort_old+token"),
                Some("https://mcp.fluxvale.com/mcp?a=1"),
            )
            .unwrap();
        assert_eq!(
            pair.access_token,
            Token::new("fvoat_raw_access_token_value")
        );

        let err = client
            .refresh(&Token::new("fvort_revoked"), None)
            .unwrap_err();
        assert_eq!(
            err,
            RefreshError::Permanent("invalid_grant: refresh token revoked".to_string())
        );

        let requests = captured_requests(&server);
        let first_body = requests[0].split("\r\n\r\n").nth(1).unwrap();
        assert_eq!(
            first_body,
            "grant_type=refresh_token&client_id=fvoc_fluxvale_cli&refresh_token=fvort_old%2Btoken&resource=https%3A%2F%2Fmcp.fluxvale.com%2Fmcp%3Fa%3D1"
        );
        let second_body = requests[1].split("\r\n\r\n").nth(1).unwrap();
        assert_eq!(
            second_body,
            "grant_type=refresh_token&client_id=fvoc_fluxvale_cli&refresh_token=fvort_revoked"
        );
    }

    /// Every failure text stays free of the refresh token. The token was on
    /// the wire in each request, or the check would prove nothing.
    fn assert_no_token_in(failures: &[RefreshError], token: &str, server: &Script) {
        for failure in failures {
            assert!(
                !failure.to_string().contains(token),
                "the text leaked the token: {failure}"
            );
            assert!(
                !format!("{failure:?}").contains(token),
                "Debug leaked the token: {failure:?}"
            );
        }
        let requests = captured_requests(server);
        assert_eq!(requests.len(), failures.len());
        for request in &requests {
            assert!(
                request.contains(&format!("refresh_token={token}")),
                "the token must have been sent for the check to mean anything"
            );
        }
    }

    #[test]
    fn an_overloaded_or_rate_limiting_endpoint_is_a_transient_refresh_failure() {
        let token = Token::new("fvort_overloaded_token_value");
        let server = script(vec![
            respond(
                "503 Service Unavailable",
                &json!({"error": "temporarily_unavailable"}),
            ),
            respond(
                "429 Too Many Requests",
                &json!({"error": "slow_down", "error_description": "try again later"}),
            ),
            respond_raw("502 Bad Gateway", "<html>bad gateway</html>"),
        ]);
        let client = OAuthDeviceClient::new(&server.base_url);

        let failures: Vec<RefreshError> = (0..3)
            .map(|_| client.refresh(&token, None).unwrap_err())
            .collect();

        assert_eq!(
            failures[0],
            RefreshError::Transient("HTTP 503: temporarily_unavailable".to_string())
        );
        assert_eq!(
            failures[1],
            RefreshError::Transient("slow_down: try again later".to_string())
        );
        assert!(
            matches!(&failures[2], RefreshError::Transient(text)
                if text.starts_with("HTTP 502: unreadable body (")),
            "err: {}",
            failures[2]
        );
        assert_no_token_in(&failures, "fvort_overloaded_token_value", &server);
    }

    #[test]
    fn a_408_from_the_endpoint_is_a_transient_refresh_failure() {
        let token = Token::new("fvort_timed_out_token_value");
        let server = script(vec![
            respond_raw("408 Request Timeout", "<html>request timeout</html>"),
            respond(
                "408 Request Timeout",
                &json!({"error": "request_timeout", "error_description": "try again"}),
            ),
        ]);
        let client = OAuthDeviceClient::new(&server.base_url);

        let failures: Vec<RefreshError> = (0..2)
            .map(|_| client.refresh(&token, None).unwrap_err())
            .collect();

        assert!(
            matches!(&failures[0], RefreshError::Transient(text)
                if text.starts_with("HTTP 408: unreadable body (")),
            "err: {}",
            failures[0]
        );
        assert_eq!(
            failures[1],
            RefreshError::Transient("request_timeout: try again".to_string())
        );
        assert_no_token_in(&failures, "fvort_timed_out_token_value", &server);
    }

    #[test]
    fn a_request_this_process_cannot_build_is_a_permanent_refresh_failure() {
        // Built by hand: each is a failure of configuration, not of the moment.
        let cannot_be_made = [
            ureq::Error::InvalidProxyUrl,
            ureq::Error::BadUri("no scheme here".to_string()),
            // A header value no request can carry.
            ureq::Error::Http("\n".parse::<ureq::http::HeaderValue>().unwrap_err().into()),
            ureq::Error::RequireHttpsOnly("http://tokens.example.test".to_string()),
            ureq::Error::TlsRequired,
        ];
        for err in cannot_be_made {
            let failure = transport_failure(err);
            assert!(
                matches!(&failure, RefreshError::Permanent(text)
                    if text.starts_with("the token request cannot be made: ")),
                "err: {failure}"
            );
        }

        // Built by hand: each is the network or the endpoint having a bad moment.
        let bad_moment = [
            ureq::Error::HostNotFound,
            ureq::Error::ConnectionFailed,
            ureq::Error::Timeout(ureq::Timeout::Global),
            ureq::Error::Io(std::io::Error::other("connection reset by peer")),
            ureq::Error::Tls("invalid peer certificate: UnknownIssuer"),
        ];
        for err in bad_moment {
            let failure = transport_failure(err);
            assert!(
                matches!(&failure, RefreshError::Transient(text) if text.starts_with("connection failed: ")),
                "err: {failure}"
            );
        }
    }

    #[test]
    fn a_base_url_that_is_not_a_uri_cannot_be_refreshed_from() {
        // ureq refuses the request before anything is sent, so this touches no
        // network. It proves refresh itself routes that failure the way
        // transport_failure says, not only that the function says so.
        let failure = OAuthDeviceClient::new("https://exa mple.test")
            .refresh(&Token::new("fvort_never_sent_token_value"), None)
            .unwrap_err();

        assert!(
            matches!(&failure, RefreshError::Permanent(text)
                if text.starts_with("the token request cannot be made: ")),
            "err: {failure}"
        );
        assert!(!failure.to_string().contains("fvort_never_sent_token_value"));
    }

    #[test]
    fn a_refusing_endpoint_is_a_permanent_refresh_failure() {
        let token = Token::new("fvort_refused_token_value");
        let server = script(vec![
            respond("401 Unauthorized", &json!({"error": "invalid_client"})),
            respond_raw("400 Bad Request", "not json"),
        ]);
        let client = OAuthDeviceClient::new(&server.base_url);

        let failures: Vec<RefreshError> = (0..2)
            .map(|_| client.refresh(&token, None).unwrap_err())
            .collect();

        assert_eq!(
            failures[0],
            RefreshError::Permanent("HTTP 401: invalid_client".to_string())
        );
        assert!(
            matches!(&failures[1], RefreshError::Permanent(text)
                if text.starts_with("HTTP 400: unreadable body (")),
            "err: {}",
            failures[1]
        );
        assert_no_token_in(&failures, "fvort_refused_token_value", &server);
    }

    #[test]
    fn an_endpoint_that_cannot_be_reached_is_a_transient_refresh_failure() {
        let token = Token::new("fvort_unanswered_token_value");
        // The request is sent, then the server hangs up before a byte of its answer.
        let hung_up = script(vec![String::new()]);
        // The request is sent and the answer's head is read, then the
        // connection drops before the body the head promised has arrived.
        let truncated = script(vec![String::from(
            "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n{\"access_token\":",
        )]);

        for server in [&hung_up, &truncated] {
            let failure = OAuthDeviceClient::new(&server.base_url)
                .refresh(&token, None)
                .unwrap_err();
            assert!(
                matches!(&failure, RefreshError::Transient(text) if text.starts_with("connection failed: ")),
                "err: {failure}"
            );
            assert_no_token_in(
                std::slice::from_ref(&failure),
                "fvort_unanswered_token_value",
                server,
            );
        }
    }

    #[test]
    fn a_200_that_is_not_a_token_pair_is_a_transient_refresh_failure() {
        let mut no_refresh = token_pair_body();
        no_refresh.as_object_mut().unwrap().remove("refresh_token");
        let mut no_expiry = token_pair_body();
        no_expiry.as_object_mut().unwrap().remove("expires_in");
        let server = script(vec![
            respond("200 OK", &no_refresh),
            respond("200 OK", &no_expiry),
            respond_raw("200 OK", r#"{"access_token": "#),
        ]);
        let client = OAuthDeviceClient::new(&server.base_url);
        let token = Token::new("fvort_oddly_answered_token_value");

        let failures: Vec<RefreshError> = (0..3)
            .map(|_| client.refresh(&token, None).unwrap_err())
            .collect();

        assert_eq!(
            failures[0],
            RefreshError::Transient("the answer carries no refresh_token".to_string())
        );
        assert_eq!(
            failures[1],
            RefreshError::Transient("the token answer carries no expires_in".to_string())
        );
        assert!(
            matches!(&failures[2], RefreshError::Transient(text)
                if text.starts_with("HTTP 200: unreadable body (")),
            "err: {}",
            failures[2]
        );
        assert_no_token_in(&failures, "fvort_oddly_answered_token_value", &server);
    }

    #[test]
    fn a_refresh_failure_prints_its_text_and_nothing_else() {
        for failure in [
            RefreshError::Transient("connection failed: dial timeout".to_string()),
            RefreshError::Permanent("invalid_grant: refresh token revoked".to_string()),
        ] {
            let (RefreshError::Transient(inner) | RefreshError::Permanent(inner)) = &failure;
            let as_error: &dyn std::error::Error = &failure;
            assert_eq!(failure.to_string(), *inner);
            assert_eq!(as_error.to_string(), *inner);
            assert_eq!(format!("{failure}"), *inner);
        }
    }

    #[test]
    fn poll_loop_sleeps_and_backs_off_on_slow_down() {
        let server = script(vec![
            respond(
                "400 Bad Request",
                &json!({"error": "authorization_pending"}),
            ),
            respond("400 Bad Request", &json!({"error": "slow_down"})),
            respond("200 OK", &token_pair_body()),
        ]);
        let rec = recorder();
        let pair = oauth_poll_loop(
            &OAuthDeviceClient::new(&server.base_url),
            "dc",
            "ver",
            5,
            rec.sleep(),
            rec.notify(),
        )
        .unwrap();
        assert_eq!(
            rec.slept(),
            vec![Duration::from_secs(5), Duration::from_secs(10)]
        );
        assert_eq!(rec.joined(), "..\n");
        assert!(!rec.joined().contains("fvoat_raw_access_token_value"));
        assert!(!rec.joined().contains("fvort_raw_refresh_token_value"));
        assert_eq!(
            pair.access_token,
            Token::new("fvoat_raw_access_token_value")
        );
    }

    #[test]
    fn poll_loop_clamps_zero_interval_and_maps_denied_and_expired() {
        let server = script(vec![
            respond(
                "400 Bad Request",
                &json!({"error": "authorization_pending"}),
            ),
            respond("200 OK", &token_pair_body()),
        ]);
        let rec = recorder();
        oauth_poll_loop(
            &OAuthDeviceClient::new(&server.base_url),
            "dc",
            "ver",
            0,
            rec.sleep(),
            rec.notify(),
        )
        .unwrap();
        assert_eq!(rec.slept(), vec![Duration::from_secs(1)]);

        let server = script(vec![respond(
            "400 Bad Request",
            &json!({"error": "access_denied"}),
        )]);
        let rec = recorder();
        let err = oauth_poll_loop(
            &OAuthDeviceClient::new(&server.base_url),
            "dc",
            "ver",
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
        let err = oauth_poll_loop(
            &OAuthDeviceClient::new(&server.base_url),
            "dc",
            "ver",
            5,
            rec.sleep(),
            rec.notify(),
        )
        .unwrap_err();
        assert_eq!(
            err.to_string(),
            "the code expired, run `fluxvale mcp login` again"
        );
    }

    fn respond_raw(status_line: &str, body: &str) -> String {
        let mut response = format!("HTTP/1.1 {status_line}\r\n");
        response.push_str(&format!("Content-Length: {}\r\n", body.len()));
        response.push_str("Connection: close\r\n\r\n");
        response.push_str(body);
        response
    }

    #[test]
    fn non_loopback_cleartext_base_url_is_refused_before_sending() {
        let client = OAuthDeviceClient::new("http://example.com");

        let mint_err = client.mint(&[], None, "challenge").unwrap_err();
        assert!(mint_err.to_string().contains("https://"));

        let poll_err = client.poll("dc", "ver").unwrap_err();
        assert!(poll_err.to_string().contains("https://"));

        let refresh_err = client.refresh(&Token::new("fvort_old"), None).unwrap_err();
        assert!(
            matches!(&refresh_err, RefreshError::Permanent(text) if text.contains("https://")),
            "err: {refresh_err}"
        );
    }

    #[test]
    fn poll_loop_retries_bounded_transient_errors_and_resets_counter() {
        let server = script(vec![
            respond_raw("502 Bad Gateway", "<html>bad gateway</html>"),
            respond_raw("429 Too Many Requests", "rate limited"),
            respond(
                "400 Bad Request",
                &json!({"error": "authorization_pending"}),
            ),
            respond_raw("503 Service Unavailable", "overloaded"),
            respond_raw("502 Bad Gateway", "<html>bad gateway</html>"),
            respond_raw("502 Bad Gateway", "<html>bad gateway</html>"),
            respond("200 OK", &token_pair_body()),
        ]);
        let rec = recorder();
        let pair = oauth_poll_loop(
            &OAuthDeviceClient::new(&server.base_url),
            "dc",
            "ver",
            5,
            rec.sleep(),
            rec.notify(),
        )
        .unwrap();
        assert_eq!(
            pair.access_token,
            Token::new("fvoat_raw_access_token_value")
        );
        assert_eq!(rec.slept().len(), 6);
    }

    #[test]
    fn poll_loop_fails_after_consecutive_transient_limit_and_immediately_on_4xx() {
        let server = script(vec![
            respond_raw("502 Bad Gateway", "<html>1</html>"),
            respond_raw("502 Bad Gateway", "<html>2</html>"),
            respond_raw("502 Bad Gateway", "<html>3</html>"),
            respond_raw("502 Bad Gateway", "<html>4</html>"),
        ]);
        let rec = recorder();
        let err = oauth_poll_loop(
            &OAuthDeviceClient::new(&server.base_url),
            "dc",
            "ver",
            5,
            rec.sleep(),
            rec.notify(),
        )
        .unwrap_err();
        assert_eq!(err.to_string(), "HTTP 502");
        assert_eq!(rec.slept().len(), 3);

        let server = script(vec![respond(
            "400 Bad Request",
            &json!({"error": "invalid_grant", "error_description": "wrong verifier"}),
        )]);
        let rec = recorder();
        let err = oauth_poll_loop(
            &OAuthDeviceClient::new(&server.base_url),
            "dc",
            "ver",
            5,
            rec.sleep(),
            rec.notify(),
        )
        .unwrap_err();
        assert_eq!(err.to_string(), "invalid_grant: wrong verifier");
        assert!(rec.slept().is_empty());
    }

    #[test]
    fn poll_loop_saturates_interval_on_slow_down_near_u64_max() {
        let server = script(vec![
            respond("400 Bad Request", &json!({"error": "slow_down"})),
            respond("200 OK", &token_pair_body()),
        ]);
        let rec = recorder();
        oauth_poll_loop(
            &OAuthDeviceClient::new(&server.base_url),
            "dc",
            "ver",
            u64::MAX - 2,
            rec.sleep(),
            rec.notify(),
        )
        .unwrap();
        assert_eq!(rec.slept(), vec![Duration::from_secs(u64::MAX)]);
    }
}
