//! The MCP server's HTTP transport, as the CLI's `mcp serve` bridge uses
//! it (#886): one POST per JSON-RPC message with the stored access
//! token as the bearer, and the answer read back as the JSON-RPC
//! messages it carries (a JSON body, a JSON array, or an SSE stream).
//! A `401` is a normal answer here: renewing the pair is the bridge's
//! job.

use crate::token::Token;
use crate::tokens::require_https_or_loopback;
use serde_json::Value;
use std::time::Duration;

/// One answered POST to the MCP server.
#[derive(Debug, PartialEq, Eq)]
pub struct McpReply {
    /// The HTTP status.
    pub status: u16,
    /// Every JSON-RPC message in the response body, in wire order.
    pub messages: Vec<Value>,
}

/// A client for one MCP endpoint. Every request carries the caller's
/// access token, so the endpoint must be `https://` or loopback, and a
/// redirect is never followed.
pub struct McpHttpClient {
    agent: ureq::Agent,
    url: String,
}

impl McpHttpClient {
    /// One request may be a long tool call.
    pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);

    /// `url` is the MCP endpoint, `https://` or a loopback `http://`.
    /// Anything else is refused here: no client, no request, no token
    /// on the wire.
    pub fn new(url: &str) -> anyhow::Result<Self> {
        require_https_or_loopback(url)?;
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            // An MCP endpoint answers directly. ureq never attaches the
            // Authorization header to a redirected request, so following
            // one would arrive unauthenticated and draw a needless renewal.
            .max_redirects(0)
            .timeout_global(Some(Self::REQUEST_TIMEOUT))
            .build()
            .into();
        Ok(McpHttpClient {
            agent,
            url: url.trim_end_matches('/').to_string(),
        })
    }

    pub fn url(&self) -> &str {
        &self.url
    }

    /// POST `body` (one JSON-RPC message, verbatim) with
    /// `Authorization: Bearer <access_token>` and, when given, the
    /// negotiated `MCP-Protocol-Version`. Every status is an answer:
    /// only a request that could not be completed is an error, and
    /// that error never carries the token.
    pub fn post(
        &self,
        access_token: &Token,
        body: &str,
        protocol_version: Option<&str>,
    ) -> anyhow::Result<McpReply> {
        let mut request = self
            .agent
            .post(&self.url)
            .header("Authorization", format!("Bearer {}", access_token.expose()))
            .header("Content-Type", "application/json")
            .header("Accept", "application/json, text/event-stream");
        if let Some(version) = protocol_version {
            request = request.header("MCP-Protocol-Version", version);
        }
        let mut response = request.send(body.as_bytes()).map_err(unreached)?;
        let status = response.status().as_u16();
        let is_sse = response
            .body()
            .mime_type()
            .is_some_and(|mime| mime.eq_ignore_ascii_case("text/event-stream"));
        let raw = response.body_mut().read_to_vec().map_err(unreached)?;
        let messages = match String::from_utf8(raw) {
            Ok(text) if is_sse => sse_messages(&text),
            Ok(text) => json_messages(&text),
            Err(_) => Vec::new(),
        };
        Ok(McpReply { status, messages })
    }
}

/// A request that did not complete: no connection, a timeout, or a
/// connection dropped before the whole answer arrived. ureq's errors
/// describe the transport, never the request headers.
fn unreached(err: ureq::Error) -> anyhow::Error {
    anyhow::anyhow!("could not reach the MCP server: {err}")
}

/// A JSON body: one object is one message, an array yields each of
/// its elements. Anything else, an empty body included, is no message.
fn json_messages(body: &str) -> Vec<Value> {
    match serde_json::from_str::<Value>(body) {
        Ok(Value::Array(items)) => items,
        Ok(message @ Value::Object(_)) => vec![message],
        Ok(_) | Err(_) => Vec::new(),
    }
}

/// An SSE body: each non-empty `data:` line is one message. The
/// `event:`, `id:` and `retry:` lines and the comments carry none.
fn sse_messages(body: &str) -> Vec<Value> {
    body.lines()
        .filter_map(|line| line.strip_prefix("data:"))
        // The spec's one optional space after the colon.
        .map(|data| data.strip_prefix(' ').unwrap_or(data))
        // An empty or non-JSON payload is no message.
        .filter_map(|data| serde_json::from_str(data).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::VecDeque;
    use std::io::{Read as _, Write as _};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    const TOKEN: &str = "fvoat_secret_access_token_never_on_the_wire";

    /// The bearer header as it arrives on the wire, lowercased.
    fn bearer() -> String {
        format!("authorization: bearer {TOKEN}")
    }

    /// A request body with characters a re-encoder could plausibly
    /// alter: the wire must carry exactly these bytes.
    const BODY: &str =
        r#"{"jsonrpc":"2.0", "id":1, "method":"tools/list", "params":{"cursor":"é ü"}}"#;

    fn result(id: i64, marker: &str) -> Value {
        json!({"jsonrpc": "2.0", "id": id, "result": {"marker": marker}})
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

    fn respond_raw(status_line: &str, body: &str) -> String {
        let mut response = format!("HTTP/1.1 {status_line}\r\n");
        response.push_str(&format!("Content-Length: {}\r\n", body.len()));
        response.push_str("Connection: close\r\n\r\n");
        response.push_str(body);
        response
    }

    /// A redirect to `location`, with nothing to read.
    fn redirect(status_line: &str, location: &str) -> String {
        let mut response = format!("HTTP/1.1 {status_line}\r\n");
        response.push_str(&format!("Location: {location}\r\n"));
        response.push_str("Content-Length: 0\r\n");
        response.push_str("Connection: close\r\n\r\n");
        response
    }

    /// Like [`respond_raw`], with the `Content-Type` the server would send.
    fn respond_typed(status_line: &str, content_type: &str, body: &str) -> String {
        let mut response = format!("HTTP/1.1 {status_line}\r\n");
        response.push_str(&format!("Content-Type: {content_type}\r\n"));
        response.push_str(&format!("Content-Length: {}\r\n", body.len()));
        response.push_str("Connection: close\r\n\r\n");
        response.push_str(body);
        response
    }

    fn captured_requests(server: &Script) -> Vec<String> {
        server.requests.lock().unwrap().clone()
    }

    /// The one request the scripted server saw: its head lowercased
    /// (header names arrive lowercased on the wire) and its body intact.
    fn captured_request(server: &Script) -> (String, String) {
        let requests = captured_requests(server);
        assert_eq!(
            requests.len(),
            1,
            "exactly one request, got {}",
            requests.len()
        );
        let (head, body) = requests[0]
            .split_once("\r\n\r\n")
            .expect("a head and a body");
        (head.to_lowercase(), body.to_owned())
    }

    fn client(server: &Script) -> McpHttpClient {
        McpHttpClient::new(&format!("{}/mcp", server.base_url)).unwrap()
    }

    /// A loopback endpoint nothing listens on. Its port number comes from
    /// the IPv6 loopback, which no scripted server in this crate binds: they
    /// all bind 127.0.0.1, so none can be handed this port in the moment
    /// between the listener going away and the connection being made. A freed
    /// 127.0.0.1 port is handed straight back out, and a test that then talks
    /// to another test's server fails them both. Where there is no IPv6
    /// loopback at all, nothing can listen on it either, so any number does.
    fn dead_endpoint() -> String {
        let port = TcpListener::bind("[::1]:0")
            .and_then(|listener| listener.local_addr().map(|addr| addr.port()))
            .unwrap_or(9);
        format!("http://[::1]:{port}/mcp")
    }

    #[test]
    fn a_json_object_body_is_one_message_and_the_request_carries_the_token() {
        let answer = result(1, "one");
        let server = script(vec![respond("200 OK", &answer)]);

        let reply = client(&server)
            .post(&Token::new(TOKEN), BODY, None)
            .unwrap();

        assert_eq!(
            reply,
            McpReply {
                status: 200,
                messages: vec![answer]
            }
        );
        let (head, body) = captured_request(&server);
        assert!(
            head.starts_with("post /mcp http/1.1"),
            "request line: {head}"
        );
        assert!(head.contains(&bearer()), "head: {head}");
        assert!(
            head.contains("content-type: application/json"),
            "head: {head}"
        );
        assert!(
            head.contains("accept: application/json, text/event-stream"),
            "head: {head}"
        );
        assert_eq!(body, BODY, "the body must arrive byte for byte");
    }

    #[test]
    fn a_json_array_body_is_its_elements_in_order() {
        let server = script(vec![respond(
            "200 OK",
            &json!([result(1, "first"), result(2, "second"), {"jsonrpc": "2.0", "method": "notifications/progress"}]),
        )]);

        let reply = client(&server)
            .post(&Token::new(TOKEN), BODY, None)
            .unwrap();

        assert_eq!(
            reply.messages,
            vec![
                result(1, "first"),
                result(2, "second"),
                json!({"jsonrpc": "2.0", "method": "notifications/progress"})
            ]
        );
        assert_eq!(reply.status, 200);
        let (head, body) = captured_request(&server);
        assert!(
            head.starts_with("post /mcp http/1.1"),
            "request line: {head}"
        );
        assert_eq!(body, BODY);
    }

    #[test]
    fn an_sse_body_is_its_data_lines_and_nothing_else() {
        let body = concat!(
            ": a comment line carries no message\n\n",
            "event: message\n",
            "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"marker\":\"first\"}}\n\n",
            "id: 42\n",
            "retry: 3000\n",
            "data:\n",
            "data:   \n",
            "data:{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"marker\":\"second\"}}\n\n",
        );
        let server = script(vec![respond_typed(
            "200 OK",
            "text/event-stream; charset=utf-8",
            body,
        )]);

        let reply = client(&server)
            .post(&Token::new(TOKEN), BODY, None)
            .unwrap();

        assert_eq!(
            reply.messages,
            vec![result(1, "first"), result(2, "second")]
        );
        assert_eq!(reply.status, 200);
        let (head, _) = captured_request(&server);
        assert!(
            head.starts_with("post /mcp http/1.1"),
            "request line: {head}"
        );
        assert!(head.contains(&bearer()), "head: {head}");
    }

    #[test]
    fn an_empty_body_is_no_message() {
        let server = script(vec![respond_raw("202 Accepted", "")]);

        let reply = client(&server)
            .post(&Token::new(TOKEN), BODY, None)
            .unwrap();

        assert_eq!(
            reply,
            McpReply {
                status: 202,
                messages: Vec::new()
            }
        );
        let (head, _) = captured_request(&server);
        assert!(
            head.starts_with("post /mcp http/1.1"),
            "request line: {head}"
        );
    }

    #[test]
    fn a_401_is_a_normal_answer() {
        let server = script(vec![respond(
            "401 Unauthorized",
            &json!({"error": "invalid_token", "error_description": "the access token expired"}),
        )]);

        let reply = client(&server)
            .post(&Token::new(TOKEN), BODY, None)
            .unwrap();

        assert_eq!(reply.status, 401);
        let (head, _) = captured_request(&server);
        assert!(
            head.contains(&bearer()),
            "the refused request still carried the token it was given: {head}"
        );
    }

    #[test]
    fn the_protocol_version_header_rides_only_when_given() {
        let server = script(vec![
            respond("200 OK", &result(1, "with header")),
            respond("200 OK", &result(2, "without header")),
        ]);
        let client = client(&server);

        let with = client
            .post(&Token::new(TOKEN), BODY, Some("2025-11-25"))
            .unwrap();
        let without = client.post(&Token::new(TOKEN), BODY, None).unwrap();

        assert_eq!(with.messages, vec![result(1, "with header")]);
        assert_eq!(without.messages, vec![result(2, "without header")]);
        let requests = captured_requests(&server);
        assert_eq!(requests.len(), 2);
        let first = requests[0].to_lowercase();
        assert!(
            first.starts_with("post /mcp http/1.1"),
            "request line: {first}"
        );
        assert!(
            first.contains("mcp-protocol-version: 2025-11-25"),
            "head: {first}"
        );
        let second = requests[1].to_lowercase();
        assert!(
            second.starts_with("post /mcp http/1.1"),
            "request line: {second}"
        );
        assert!(!second.contains("mcp-protocol-version"), "head: {second}");
    }

    #[test]
    fn a_cleartext_remote_endpoint_is_refused_before_any_request() {
        // No client comes back, so there is nothing a request could leave through.
        let Err(err) = McpHttpClient::new("http://example.com/mcp") else {
            panic!("a cleartext remote endpoint must be refused");
        };

        assert!(err.to_string().contains("https://"), "err: {err}");
        for refused in [
            "ftp://fluxvale.com/mcp",
            "fluxvale.com/mcp",
            "http://127.0.0.1.evil.test/mcp",
        ] {
            assert!(
                McpHttpClient::new(refused).is_err(),
                "{refused} must be refused"
            );
        }
    }

    #[test]
    fn the_client_waits_for_a_slow_tool_call_and_answers_every_status() {
        let client = McpHttpClient::new("https://mcp.fluxvale.com/mcp").unwrap();

        assert_eq!(McpHttpClient::REQUEST_TIMEOUT, Duration::from_secs(120));
        // The client must be built with it: a constant nobody uses guards nothing.
        let config = client.agent.config();
        assert_eq!(
            config.timeouts().global,
            Some(McpHttpClient::REQUEST_TIMEOUT)
        );
        assert!(
            !config.http_status_as_error(),
            "a 401 comes back as an answer for the caller to renew on"
        );
        assert_eq!(config.max_redirects(), 0, "a redirect is never followed");
    }

    #[test]
    fn a_redirect_is_not_followed() {
        // The second answer is the redirect target's. It must never be served.
        let server = script(vec![
            redirect("302 Found", "/elsewhere"),
            respond("200 OK", &result(1, "the redirect target")),
        ]);

        let reply = client(&server)
            .post(&Token::new(TOKEN), BODY, None)
            .unwrap();

        assert_eq!(
            reply,
            McpReply {
                status: 302,
                messages: Vec::new()
            }
        );
        let requests = captured_requests(&server);
        assert_eq!(requests.len(), 1, "the redirect target was requested");
        assert!(
            requests[0].to_lowercase().starts_with("post /mcp http/1.1"),
            "request line: {}",
            requests[0]
        );
    }

    #[test]
    fn the_url_loses_its_trailing_slashes() {
        assert_eq!(
            McpHttpClient::new("https://mcp.fluxvale.com/mcp///")
                .unwrap()
                .url(),
            "https://mcp.fluxvale.com/mcp"
        );
        assert_eq!(
            McpHttpClient::new("http://127.0.0.1:4600/mcp/")
                .unwrap()
                .url(),
            "http://127.0.0.1:4600/mcp"
        );
        // Loopback cleartext is the one http:// a client is built for.
        assert!(McpHttpClient::new("http://[::1]:4600/mcp").is_ok());
        assert!(McpHttpClient::new("http://localhost:4600/mcp").is_ok());
    }

    #[test]
    fn a_body_that_is_neither_json_nor_sse_is_no_message() {
        for content_type in ["text/html", "application/json", ""] {
            let server = script(vec![respond_typed(
                "502 Bad Gateway",
                content_type,
                "<html>bad gateway</html>",
            )]);

            let reply = client(&server)
                .post(&Token::new(TOKEN), BODY, None)
                .unwrap();

            assert_eq!(
                reply,
                McpReply {
                    status: 502,
                    messages: Vec::new()
                },
                "{content_type}"
            );
            let (head, _) = captured_request(&server);
            assert!(
                head.starts_with("post /mcp http/1.1"),
                "request line: {head}"
            );
        }
        // A lone JSON scalar is not a message either.
        let server = script(vec![respond_raw("200 OK", "42")]);
        let reply = client(&server)
            .post(&Token::new(TOKEN), BODY, None)
            .unwrap();
        assert!(reply.messages.is_empty());
    }

    #[test]
    fn a_connection_failure_is_an_error_that_names_no_token() {
        // Nothing listens at the endpoint at all.
        let refused = McpHttpClient::new(&dead_endpoint()).unwrap();

        let err = refused.post(&Token::new(TOKEN), BODY, None).unwrap_err();

        let message = err.to_string();
        assert!(
            message.contains("could not reach the MCP server"),
            "err: {message}"
        );
        assert!(
            !message.contains(TOKEN),
            "the error leaked the token: {message}"
        );

        // A server that takes the request and hangs up before answering.
        let server = script(vec![String::new()]);
        let dropped = client(&server);

        let err = dropped
            .post(&Token::new(TOKEN), BODY, Some("2025-11-25"))
            .unwrap_err();

        let message = err.to_string();
        assert!(
            message.contains("could not reach the MCP server"),
            "err: {message}"
        );
        assert!(
            !message.contains(TOKEN),
            "the error leaked the token: {message}"
        );
        let (head, body) = captured_request(&server);
        assert!(
            head.starts_with("post /mcp http/1.1"),
            "request line: {head}"
        );
        assert!(
            head.contains("mcp-protocol-version: 2025-11-25"),
            "head: {head}"
        );
        assert_eq!(body, BODY);
    }
}
