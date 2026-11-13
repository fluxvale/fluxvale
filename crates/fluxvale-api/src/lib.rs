//! The FluxVale `/api/v1` client crate — base_url + token over ureq
//! (rustls), speaking JSON:API — `Authorization: Bearer`, `Accept:
//! application/vnd.api+json`. Typed resource structs live in
//! [`types`] (generated); response parsing stays loose here
//! ([`jsonapi`]). The RFC 8628 device flow — plain JSON,
//! unauthenticated by design — lives in [`device`]; the redacted
//! token value type in [`token`]. Shared by the CLI and the MCP
//! server (#484).

pub mod device;
pub mod error;
pub mod jsonapi;
pub mod terraform;
pub mod token;
pub mod types;

pub use device::{DeviceClient, Minted, Poll, poll_loop};
pub use error::ApiError;
pub use jsonapi::{Document, Resource};
pub use token::Token;

use serde_json::Value;
use std::time::Duration;

/// The `/api/v1` prefix every artifact path carries.
const API_PREFIX: &str = "/api/v1";

/// A client for one base URL + one token.
#[derive(Debug)]
pub struct ApiClient {
    agent: ureq::Agent,
    base_url: String,
    token: Token,
}

impl ApiClient {
    pub fn new(base_url: &str, token: Token) -> Self {
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .http_status_as_error(false) // statuses map to ApiError, not ureq::Error
            .timeout_global(Some(Duration::from_secs(30)))
            .build()
            .into();
        ApiClient {
            agent,
            base_url: base_url.trim_end_matches('/').to_string(),
            token,
        }
    }

    /// The canonical origin this client addresses — the Terraform
    /// scaffold carries it when it differs from the provider's
    /// production default.
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// GET a collection or resource (a JSON:API document).
    pub fn get(&self, path: &str) -> Result<Document, ApiError> {
        let url = self.url(path);
        self.finish(self.headers(self.agent.get(&url)).call())
    }

    /// GET a plain JSON body — the runway projection answers a bare
    /// object, not an envelope (wallet_route_test's contract).
    pub fn get_json(&self, path: &str) -> Result<serde_json::Value, ApiError> {
        let url = self.url(path);
        self.finish(self.headers(self.agent.get(&url)).call())
    }

    /// Send a request and parse the JSON:API document on success.
    pub fn send(
        &self,
        method: &str,
        path: &str,
        body: Option<String>,
    ) -> Result<Document, ApiError> {
        self.request(method, path, body)
    }

    /// Send a request and parse a bare JSON body — the generic-action
    /// routes (run/restore, the gateway pairing verbs) answer flat
    /// objects, not JSON:API envelopes (backup_route_test's contract).
    pub fn send_json(
        &self,
        method: &str,
        path: &str,
        body: Option<String>,
    ) -> Result<Value, ApiError> {
        self.request(method, path, body)
    }

    fn request<T: serde::de::DeserializeOwned>(
        &self,
        method: &str,
        path: &str,
        body: Option<String>,
    ) -> Result<T, ApiError> {
        let url = self.url(path);
        match (method, body) {
            ("GET" | "DELETE", Some(_)) => {
                Err(ApiError::Transport(format!("{method} takes no body")))
            }
            ("GET", None) => self.finish(self.headers(self.agent.get(&url)).call()),
            ("DELETE", None) => self.finish(self.headers(self.agent.delete(&url)).call()),
            // A body rides the JSON:API media type.
            ("POST" | "PATCH", Some(body)) => {
                let request = match method {
                    "POST" => self.agent.post(&url),
                    _ => self.agent.patch(&url),
                };
                self.finish(
                    self.headers(request)
                        .header("Content-Type", "application/vnd.api+json")
                        .send(body.into_bytes()),
                )
            }
            // Bodyless POST/PATCH rides like the platform's own route
            // tests: neither body nor content type — a Content-Type
            // with empty bytes would make the server try to parse "".
            ("POST" | "PATCH", None) => {
                let request = match method {
                    "POST" => self.agent.post(&url),
                    _ => self.agent.patch(&url),
                };
                self.finish(self.headers(request).send(Vec::new()))
            }
            (other, _) => Err(ApiError::Transport(format!("unsupported method {other}"))),
        }
    }

    fn url(&self, path: &str) -> String {
        format!("{}{API_PREFIX}{path}", self.base_url)
    }

    fn headers<S>(&self, request: ureq::RequestBuilder<S>) -> ureq::RequestBuilder<S> {
        request
            .header("Authorization", format!("Bearer {}", self.token.expose()))
            .header("Accept", "application/vnd.api+json")
    }

    fn finish<T: serde::de::DeserializeOwned>(
        &self,
        response: Result<ureq::http::Response<ureq::Body>, ureq::Error>,
    ) -> Result<T, ApiError> {
        match response {
            Ok(mut response) => {
                let status = response.status().as_u16();
                let retry_after = response
                    .headers()
                    .get("Retry-After")
                    .and_then(|value| value.to_str().ok())
                    .map(str::to_owned);
                let body = response
                    .body_mut()
                    .read_to_string()
                    .map_err(|err| ApiError::Transport(err.to_string()))?;
                if (200..300).contains(&status) {
                    serde_json::from_str(&body)
                        .map_err(|err| ApiError::Api(format!("unexpected response body: {err}")))
                } else {
                    Err(error::map_response(status, retry_after.as_deref(), &body))
                }
            }
            Err(err) => Err(ApiError::Transport(err.to_string())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read as _, Write as _};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    /// A one-shot HTTP server: accepts exactly one request, captures
    /// the raw request head, replies with the canned response.
    struct OneShot {
        base_url: String,
        captured_head: Arc<Mutex<String>>,
    }

    fn serve(response: &str) -> OneShot {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let captured_head = Arc::new(Mutex::new(String::new()));
        let captured = captured_head.clone();
        let response = response.to_string();
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut head = String::new();
            let mut buf = [0u8; 4096];
            // GET/PATCH bodies don't matter here; read until the head
            // terminator arrives.
            while !head.contains("\r\n\r\n") {
                let read = stream.read(&mut buf).unwrap();
                if read == 0 {
                    break;
                }
                head.push_str(&String::from_utf8_lossy(&buf[..read]));
            }
            *captured.lock().unwrap() = head;
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.flush();
        });
        OneShot {
            base_url: format!("http://{addr}"),
            captured_head,
        }
    }

    fn respond(status_line: &str, headers: &[(&str, &str)], body: &str) -> String {
        let mut response = format!("HTTP/1.1 {status_line}\r\n");
        for (name, value) in headers {
            response.push_str(&format!("{name}: {value}\r\n"));
        }
        response.push_str(&format!("Content-Length: {}\r\n", body.len()));
        response.push_str("Connection: close\r\n\r\n");
        response.push_str(body);
        response
    }

    fn document_body() -> String {
        r#"{"data":{"type":"user","id":"01H","attributes":{"platform_role":"user"}}}"#.to_string()
    }

    fn client(base_url: &str) -> ApiClient {
        ApiClient::new(base_url, Token::new("fvpat_testtoken"))
    }

    #[test]
    fn success_parses_the_document() {
        let server = serve(&respond(
            "200 OK",
            &[("Content-Type", "application/vnd.api+json")],
            &document_body(),
        ));
        let document = client(&server.base_url).get("/me").unwrap();
        assert_eq!(document.resources()[0].r#type, "user");
    }

    #[test]
    fn sends_bearer_and_accept_headers() {
        let server = serve(&respond("200 OK", &[], &document_body()));
        let _ = client(&server.base_url).get("/me").unwrap();
        // Header names arrive lowercased on the wire.
        let head = server.captured_head.lock().unwrap().to_lowercase();
        assert!(
            head.starts_with("get /api/v1/me http/1.1"),
            "request line: {head}"
        );
        assert!(
            head.contains("authorization: bearer fvpat_testtoken"),
            "head: {head}"
        );
        assert!(
            head.contains("accept: application/vnd.api+json"),
            "head: {head}"
        );
    }

    #[test]
    fn url_joins_base_and_prefix() {
        let server = serve(&respond("200 OK", &[], &document_body()));
        let base = format!("{}/", server.base_url); // trailing slash must not double
        let _ = client(&base).get("/me").unwrap();
        let head = server.captured_head.lock().unwrap().clone();
        assert!(head.contains("GET /api/v1/me HTTP/1.1"), "head: {head}");
    }

    #[test]
    fn get_json_parses_a_non_envelope_body() {
        // The runway projection answers a bare map — no `data` wrapper.
        let body =
            r#"{"balance_cents":400,"burn_micro_cents_per_hour":0,"runway_hours":"infinity"}"#;
        let server = serve(&respond("200 OK", &[], body));
        let map = client(&server.base_url)
            .get_json("/organizations/o/wallet/runway")
            .unwrap();
        assert_eq!(map["balance_cents"], 400);
        assert_eq!(map["runway_hours"], "infinity");
    }

    #[test]
    fn unauthorized_maps_friendly() {
        let body = r#"{"errors":[{"status":"401","title":"Unauthorized"}]}"#;
        let server = serve(&respond("401 Unauthorized", &[], body));
        let err = client(&server.base_url).get("/me").unwrap_err();
        assert_eq!(
            err.to_string(),
            "not signed in or token revoked (fluxvale auth login)"
        );
    }

    #[test]
    fn forbidden_detail_passes_verbatim() {
        let body = r#"{"errors":[{"status":"403","title":"Forbidden","detail":"token lacks the instances:write scope"}]}"#;
        let server = serve(&respond("403 Forbidden", &[], body));
        let err = client(&server.base_url).get("/instances").unwrap_err();
        assert_eq!(
            err.to_string(),
            "403 Forbidden: token lacks the instances:write scope"
        );
    }

    #[test]
    fn rate_limited_includes_retry_after() {
        let server = serve(&respond(
            "429 Too Many Requests",
            &[("Retry-After", "12")],
            r#"{"errors":[]}"#,
        ));
        let err = client(&server.base_url).get("/instances").unwrap_err();
        assert_eq!(err.to_string(), "rate limited, retry in 12s");
    }

    #[test]
    fn patch_sends_the_body() {
        // A PATCH whose request body we verify server-side.
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let body = r#"{"data":{"type":"instance","id":"1","attributes":{"status":"stopped"}}}"#;
        let response = respond("200 OK", &[], body);
        let captured_head = Arc::new(Mutex::new(String::new()));
        let captured = captured_head.clone();
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut raw = Vec::new();
            let mut buf = [0u8; 8192];
            loop {
                let read = stream.read(&mut buf).unwrap();
                if read == 0 {
                    break;
                }
                raw.extend_from_slice(&buf[..read]);
                let head_end = raw.windows(4).position(|w| w == b"\r\n\r\n").map(|p| p + 4);
                if let Some(end) = head_end {
                    let text = String::from_utf8_lossy(&raw).to_lowercase();
                    let length: usize = text
                        .split("\r\n")
                        .find_map(|line| {
                            line.strip_prefix("content-length: ")
                                .map(|v| v.trim().parse().ok())
                        })
                        .flatten()
                        .unwrap_or(0);
                    if raw.len() >= end + length {
                        break;
                    }
                }
            }
            *captured.lock().unwrap() = String::from_utf8_lossy(&raw).to_string();
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.flush();
        });
        let base = format!("http://{addr}");
        let document = client(&base)
            .send("PATCH", "/instances/1/stop", Some(body.to_owned()))
            .unwrap();
        assert_eq!(document.resources()[0].id, "1");
        // Header names arrive lowercased on the wire.
        let head = captured_head.lock().unwrap().to_lowercase();
        assert!(
            head.contains("patch /api/v1/instances/1/stop"),
            "head: {head}"
        );
        assert!(
            head.contains("content-type: application/vnd.api+json"),
            "head: {head}"
        );
        assert!(head.contains(body), "patch body must arrive intact");
    }

    #[test]
    fn transport_failure_maps_to_transport() {
        // Bind, learn a free port, then drop — connection refused.
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        drop(listener);
        let err = client(&format!("http://{addr}")).get("/me").unwrap_err();
        assert!(matches!(err, ApiError::Transport(_)), "got: {err:?}");
    }

    #[test]
    fn bodyless_post_rides_without_a_content_type() {
        // The generic-action routes (run/restore) take their arguments
        // from the path: the platform's route tests POST with neither
        // body nor content type, and so must the client.
        let server = serve(&respond(
            "200 OK",
            &[],
            r#"{"kind":"manual","status":"running"}"#,
        ));
        let row = client(&server.base_url)
            .send_json("POST", "/instances/i1/backup-runs", None)
            .unwrap();
        assert_eq!(row["kind"], "manual");
        let head = server.captured_head.lock().unwrap().to_lowercase();
        assert!(
            head.starts_with("post /api/v1/instances/i1/backup-runs http/1.1"),
            "request line: {head}"
        );
        assert!(
            !head.contains("content-type:"),
            "bodyless POST must not claim a media type: {head}"
        );
    }

    #[test]
    fn bodyless_patch_rides_without_a_content_type_too() {
        // The PATCH None arm: same posture as the bodyless POST.
        let server = serve(&respond("200 OK", &[], r#"{"state":"provisioning"}"#));
        let row = client(&server.base_url)
            .send_json("PATCH", "/access-gateways/g1/resume", None)
            .unwrap();
        assert_eq!(row["state"], "provisioning");
        let head = server.captured_head.lock().unwrap().to_lowercase();
        assert!(
            head.starts_with("patch /api/v1/access-gateways/g1/resume http/1.1"),
            "request line: {head}"
        );
        assert!(
            !head.contains("content-type:"),
            "bodyless PATCH must not claim a media type: {head}"
        );
    }

    #[test]
    fn send_json_parses_the_generic_actions_flat_body() {
        // {"success":true} — the detach verb's whole answer.
        let server = serve(&respond("200 OK", &[], r#"{"success":true}"#));
        let row = client(&server.base_url)
            .send_json("DELETE", "/access-gateways/g1/attachments/i1", None)
            .unwrap();
        assert_eq!(row["success"], true);
        let head = server.captured_head.lock().unwrap().to_lowercase();
        assert!(
            head.starts_with("delete /api/v1/access-gateways/g1/attachments/i1 http/1.1"),
            "request line: {head}"
        );
    }

    #[test]
    fn error_statuses_reject_flat_bodies_too() {
        // A generic action's refusal (400 + the guard words) maps the
        // same way on send_json as on the envelope reads.
        let server = serve(&respond(
            "400 Bad Request",
            &[],
            r#"{"errors":[{"detail":"backups are not configured for this instance"}]}"#,
        ));
        let err = client(&server.base_url)
            .send_json("POST", "/instances/i1/backup-runs", None)
            .unwrap_err();
        assert!(
            err.to_string().contains("backups are not configured"),
            "error: {err}"
        );
    }
}
