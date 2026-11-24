//! The MCP server's HTTP transport, as the CLI's `mcp serve` bridge uses
//! it (#886): one POST per JSON-RPC message with the stored access
//! token as the bearer, and the answer read back as the JSON-RPC
//! messages it carries (a JSON body, a JSON array, or an SSE stream).
//! Only JSON-RPC messages come back: a gateway's plain JSON error is for
//! the caller to read off the status. From protocol version 2026-07-28 a
//! request also carries the standard `Mcp-Method` and `Mcp-Name` headers.
//! A `401` is a normal answer here, its body read or not: renewing the pair
//! is the bridge's job.

use crate::token::Token;
use crate::tokens::require_https_or_loopback;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::Value;
use std::time::Duration;

/// The first protocol version whose requests carry `Mcp-Method` and
/// `Mcp-Name`. The server compares version strings as they are.
const STANDARD_HEADERS_FROM: &str = "2026-07-28";

/// One answered POST to the MCP server.
#[derive(Debug, PartialEq, Eq)]
pub struct McpReply {
    /// The HTTP status.
    pub status: u16,
    /// Every JSON-RPC message in the response body, in wire order. A
    /// body that carries none gives an empty list, whatever its status.
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
    /// `Authorization: Bearer <access_token>`, `Content-Type` and
    /// `Accept`, and, when given, `MCP-Protocol-Version`.
    ///
    /// From protocol version `2026-07-28` the server also requires the
    /// standard request headers, so a request then carries `Mcp-Method`,
    /// and `Mcp-Name` for the methods that name something, encoded as
    /// rmcp's client encodes it: as it is when it survives as a header
    /// value, else as `=?base64?<base64>?=`. `Mcp-Param-*` headers are
    /// not sent. They carry a tool argument that the tool's schema lifts
    /// into a header with `x-mcp-header`, and the FluxVale server's tools
    /// declare none, so there is nothing to send.
    ///
    /// Every status is an answer: only a request that could not be
    /// completed is an error, and that error never carries the token.
    /// A `401` whose body cannot be read is still that answer, with no
    /// messages.
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
            if version >= STANDARD_HEADERS_FROM {
                for (name, value) in standard_headers(body) {
                    request = request.header(name, value.as_str());
                }
            }
        }
        let mut response = request.send(body.as_bytes()).map_err(unreached)?;
        let status = response.status().as_u16();
        let is_sse = response
            .body()
            .mime_type()
            .is_some_and(|mime| mime.eq_ignore_ascii_case("text/event-stream"));
        let raw = match response.body_mut().read_to_vec() {
            Ok(raw) => raw,
            // A 401's meaning is in its status, and the bridge renews on
            // it. A body that cannot be read does not change that.
            Err(_) if status == 401 => {
                return Ok(McpReply {
                    status,
                    messages: Vec::new(),
                });
            }
            Err(err) => return Err(unreached(err)),
        };
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

/// A JSON-RPC 2.0 message: an object whose `jsonrpc` is `"2.0"` that
/// carries a string `method`, or a `result`, or an `error`. Anything else
/// in a body, a gateway's plain JSON error for one, is not a message.
fn is_json_rpc_message(value: &Value) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    if object.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
        return false;
    }
    object.get("method").is_some_and(Value::is_string)
        || object.contains_key("result")
        || object.contains_key("error")
}

/// A JSON body: an object is one message and an array yields each of its
/// elements, and only those that are JSON-RPC messages. Anything else, an
/// empty body included, is no message.
fn json_messages(body: &str) -> Vec<Value> {
    match serde_json::from_str::<Value>(body) {
        Ok(Value::Array(items)) => items.into_iter().filter(is_json_rpc_message).collect(),
        Ok(message @ Value::Object(_)) if is_json_rpc_message(&message) => vec![message],
        Ok(_) | Err(_) => Vec::new(),
    }
}

/// An SSE body: one event is one message. Events are separated by blank
/// lines, and a last event with no blank line after it is still one, since
/// the body is complete by the time it gets here. An event's `data:` lines
/// are joined with a newline, after each line's one optional leading space
/// is removed, and the joined text is a message when it parses to one. The
/// `event:`, `id:` and `retry:` lines and the comments carry no data. A line
/// may end with `\n`, `\r\n` or `\r`.
fn sse_messages(body: &str) -> Vec<Value> {
    // One line ending for all, so a blank line is found the same way.
    let text = body.replace("\r\n", "\n").replace('\r', "\n");
    text.split("\n\n")
        .filter_map(|event| {
            let data = event
                .lines()
                .filter_map(|line| line.strip_prefix("data:"))
                // The spec's one optional space after the colon.
                .map(|data| data.strip_prefix(' ').unwrap_or(data))
                .collect::<Vec<_>>()
                .join("\n");
            serde_json::from_str(&data).ok()
        })
        .filter(is_json_rpc_message)
        .collect()
}

/// The `Mcp-Method` and `Mcp-Name` headers of a request body. A body that
/// is not a JSON object with a string `method` gets none.
fn standard_headers(body: &str) -> Vec<(&'static str, String)> {
    let Ok(message) = serde_json::from_str::<Value>(body) else {
        return Vec::new();
    };
    let Some(method) = message.get("method").and_then(Value::as_str) else {
        return Vec::new();
    };
    let mut headers = vec![("Mcp-Method", method.to_owned())];
    if let Some(member) = named_by(method)
        && let Some(name) = message
            .get("params")
            .and_then(|params| params.get(member))
            .and_then(Value::as_str)
    {
        headers.push(("Mcp-Name", encode_header_value(name)));
    }
    headers
}

/// The member of `params` that names what a method acts on, for the
/// methods that have one.
fn named_by(method: &str) -> Option<&'static str> {
    match method {
        "tools/call" | "prompts/get" => Some("name"),
        "resources/read" | "resources/subscribe" | "resources/unsubscribe" => Some("uri"),
        "tasks/get" | "tasks/update" | "tasks/cancel" => Some("taskId"),
        _ => None,
    }
}

/// A name as rmcp's client puts it in a header: as it is when every
/// character is printable ASCII, with no space or tab at either end, and
/// it does not already look encoded. Else wrapped in `=?base64?` and `?=`.
fn encode_header_value(value: &str) -> String {
    if requires_base64(value) {
        format!("=?base64?{}?=", STANDARD.encode(value.as_bytes()))
    } else {
        value.to_owned()
    }
}

fn requires_base64(value: &str) -> bool {
    if value.is_empty() {
        return false;
    }
    let bytes = value.as_bytes();
    let edged =
        matches!(bytes.first(), Some(b' ' | b'\t')) || matches!(bytes.last(), Some(b' ' | b'\t'));
    edged
        || !value.is_ascii()
        || value.chars().any(|c| c.is_ascii_control())
        || (value.starts_with("=?base64?") && value.ends_with("?="))
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
        script_bytes(responses.into_iter().map(String::into_bytes).collect())
    }

    fn script_bytes(responses: Vec<Vec<u8>>) -> Script {
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
                let _ = stream.write_all(&response);
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

    /// The one request the scripted server saw, as it sent it: its head
    /// with the header names and values in their original case, and its body.
    fn captured_request_as_sent(server: &Script) -> (String, String) {
        let requests = captured_requests(server);
        assert_eq!(requests.len(), 1, "exactly one request");
        requests[0]
            .split_once("\r\n\r\n")
            .map(|(head, body)| (head.to_owned(), body.to_owned()))
            .expect("a head and a body")
    }

    /// A JSON-RPC request as a client might space it.
    fn request(method: &str, params: &Value) -> String {
        json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).to_string()
    }

    /// Posts `body` once with `version` and returns the head of the one
    /// request the scripted server saw, as it was sent. The body must ride as it is.
    fn posted_head(body: &str, version: Option<&str>) -> String {
        let server = script(vec![respond("200 OK", &result(1, "ok"))]);
        client(&server)
            .post(&Token::new(TOKEN), body, version)
            .unwrap();
        let (head, sent) = captured_request_as_sent(&server);
        assert_eq!(sent, body, "the body must ride as it is");
        assert!(
            head.starts_with("POST /mcp HTTP/1.1"),
            "request line: {head}"
        );
        head
    }

    /// The value of header `name` in a request head as it was sent. The
    /// name is matched without regard to case, the value is taken as it is.
    fn header<'a>(head: &'a str, name: &str) -> Option<&'a str> {
        let prefix = format!("{name}: ");
        let line = head.split("\r\n").skip(1).find(|line| {
            line.get(..prefix.len())
                .is_some_and(|start| start.eq_ignore_ascii_case(&prefix))
        })?;
        Some(&line[prefix.len()..])
    }

    /// The first version whose requests carry `Mcp-Method` and `Mcp-Name`.
    const NEW: &str = "2026-07-28";

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
    fn a_json_array_keeps_only_its_json_rpc_messages_in_order() {
        let first = result(1, "first");
        let server = script(vec![respond(
            "200 OK",
            &json!([first, {"jsonrpc": "2.0", "method": "notifications/progress"}, {"n": 1}]),
        )]);

        let reply = client(&server)
            .post(&Token::new(TOKEN), BODY, None)
            .unwrap();

        assert_eq!(
            reply.messages,
            vec![
                first,
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
    fn only_a_json_rpc_20_message_is_a_message() {
        for message in [
            json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}),
            json!({"jsonrpc": "2.0", "method": "notifications/progress"}),
            json!({"jsonrpc": "2.0", "id": 1, "result": {}}),
            json!({"jsonrpc": "2.0", "id": 1, "error": {"code": -1}}),
        ] {
            assert!(is_json_rpc_message(&message), "{message}");
        }
        for not_one in [
            // Another protocol version, or the member is not the string "2.0".
            json!({"jsonrpc": "1.0", "method": "x"}),
            json!({"jsonrpc": 2.0, "method": "x"}),
            // No method, result or error.
            json!({"jsonrpc": "2.0", "id": 1}),
            json!({"jsonrpc": "2.0", "method": 7}),
            // A gateway's or a JSON:API error document.
            json!({"error": "insufficient_scope"}),
            json!({"errors": [{"detail": "upstream down"}]}),
            // Not an object.
            json!([]),
            json!("x"),
            json!(42),
            json!(null),
        ] {
            assert!(!is_json_rpc_message(&not_one), "{not_one}");
        }
    }

    #[test]
    fn an_sse_body_keeps_only_its_json_rpc_messages() {
        let real = result(1, "the real one");
        // Each value that is no message sits in an event of its own. In the
        // last event the empty and the blank data line join to whitespace
        // in front of the real one.
        let body = format!(
            concat!(
                ": a comment line carries no message\n\n",
                "event: message\n",
                "data: 42\n\n",
                "id: 42\n",
                "retry: 3000\n",
                "data: {{\"jsonrpc\":\"1.0\",\"method\":\"x\"}}\n\n",
                "data:\n",
                "data:   \n",
                "data: {real}\n\n",
            ),
            real = real
        );
        let server = script(vec![respond_typed(
            "200 OK",
            "text/event-stream; charset=utf-8",
            &body,
        )]);

        let reply = client(&server)
            .post(&Token::new(TOKEN), BODY, None)
            .unwrap();

        assert_eq!(reply.messages, vec![real]);
        assert_eq!(reply.status, 200);
        let (head, _) = captured_request(&server);
        assert!(head.contains(&bearer()), "head: {head}");
    }

    /// What the client reads back from an SSE body. The request is checked
    /// to have carried the token, as in the other tests.
    fn sse_reply(body: &str) -> McpReply {
        let server = script(vec![respond_typed(
            "200 OK",
            "text/event-stream; charset=utf-8",
            body,
        )]);

        let reply = client(&server)
            .post(&Token::new(TOKEN), BODY, None)
            .unwrap();

        let (head, _) = captured_request(&server);
        assert!(head.contains(&bearer()), "head: {head}");
        reply
    }

    #[test]
    fn one_sse_event_is_one_message_across_its_data_lines() {
        // The second line has no space after the colon: that space is optional.
        let body = concat!(
            "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\n",
            "data:{\"ok\":true}}\n\n",
        );

        let reply = sse_reply(body);

        assert_eq!(
            reply.messages,
            vec![json!({"jsonrpc": "2.0", "id": 1, "result": {"ok": true}})]
        );
        assert_eq!(reply.status, 200);
    }

    #[test]
    fn two_sse_events_are_two_messages_in_order() {
        let body = concat!(
            "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"marker\":\"first\"}}\n\n",
            "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"marker\":\"second\"}}\n\n",
        );

        let reply = sse_reply(body);

        assert_eq!(
            reply.messages,
            vec![result(1, "first"), result(2, "second")]
        );
        assert_eq!(reply.status, 200);
    }

    #[test]
    fn a_last_sse_event_with_no_blank_line_after_it_is_delivered() {
        let body = concat!(
            "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"marker\":\"first\"}}\n\n",
            "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"marker\":\"last\"}}",
        );

        let reply = sse_reply(body);

        assert_eq!(reply.messages, vec![result(1, "first"), result(2, "last")]);
        assert_eq!(reply.status, 200);
    }

    #[test]
    fn an_sse_body_may_end_its_lines_with_crlf_or_cr() {
        // A comment, an `event:` line, and an event split across two data
        // lines, then a last event with no blank line after it.
        let body = concat!(
            ": a comment carries no data\n\n",
            "event: message\n",
            "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\n",
            "data: {\"marker\":\"first\"}}\n\n",
            "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"marker\":\"last\"}}",
        );
        let expected = vec![result(1, "first"), result(2, "last")];

        assert_eq!(sse_reply(body).messages, expected, "lines end with \\n");
        assert_eq!(
            sse_reply(&body.replace('\n', "\r\n")).messages,
            expected,
            "lines end with \\r\\n"
        );
        assert_eq!(
            sse_reply(&body.replace('\n', "\r")).messages,
            expected,
            "lines end with \\r"
        );
    }

    #[test]
    fn a_gateway_error_is_no_message() {
        let server = script(vec![respond(
            "200 OK",
            &json!({"error": "insufficient_scope", "error_description": "missing instances:read"}),
        )]);

        let reply = client(&server)
            .post(&Token::new(TOKEN), BODY, None)
            .unwrap();

        assert_eq!(
            reply,
            McpReply {
                status: 200,
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
    fn a_jsonapi_error_document_is_no_message() {
        let server = script(vec![respond(
            "200 OK",
            &json!({"errors": [{"detail": "upstream down"}]}),
        )]);

        let reply = client(&server)
            .post(&Token::new(TOKEN), BODY, None)
            .unwrap();

        assert_eq!(
            reply,
            McpReply {
                status: 200,
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
    fn a_body_that_is_not_utf8_is_no_message() {
        let mut response =
            b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\n".to_vec();
        response.extend_from_slice(&[0xff, 0xfe, 0xfd]);
        let server = script_bytes(vec![response]);

        let reply = client(&server).post(&Token::new(TOKEN), BODY, None);

        assert_eq!(
            reply.unwrap(),
            McpReply {
                status: 200,
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
    fn a_401_whose_body_is_cut_short_is_still_a_401() {
        // The head promises ten bytes more than are ever written, then the
        // connection closes. The status alone is the answer.
        let body = r#"{"error":"invalid_token"}"#;
        let mut response = format!(
            "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len() + 10
        )
        .into_bytes();
        response.truncate(response.len() - 10);
        let server = script_bytes(vec![response]);

        let reply = client(&server)
            .post(&Token::new(TOKEN), BODY, None)
            .unwrap();

        assert_eq!(
            reply,
            McpReply {
                status: 401,
                messages: Vec::new()
            }
        );
        let (head, _) = captured_request(&server);
        assert!(
            head.starts_with("post /mcp http/1.1"),
            "request line: {head}"
        );
        assert!(head.contains(&bearer()), "head: {head}");
    }

    #[test]
    fn a_body_shorter_than_its_content_length_is_an_error() {
        // The head promises ten bytes more than are ever written, then the
        // connection closes.
        let body = result(1, "cut off").to_string();
        let mut response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len() + 10
        )
        .into_bytes();
        response.truncate(response.len() - 10);
        let server = script_bytes(vec![response]);

        let err = client(&server)
            .post(&Token::new(TOKEN), BODY, None)
            .unwrap_err();

        let message = err.to_string();
        assert!(
            message.starts_with("could not reach the MCP server: "),
            "err: {message}"
        );
        assert!(
            !message.contains(TOKEN),
            "the error leaked the token: {message}"
        );
        let (head, _) = captured_request(&server);
        assert!(
            head.starts_with("post /mcp http/1.1"),
            "request line: {head}"
        );
    }

    #[test]
    fn from_2026_07_28_a_request_carries_its_method() {
        // The method names nothing, whatever its params carry.
        let head = posted_head(
            &request("server/discover", &json!({"name": "a decoy"})),
            Some(NEW),
        );

        assert_eq!(header(&head, "mcp-method"), Some("server/discover"));
        assert_eq!(header(&head, "mcp-name"), None, "the method names nothing");
        assert_eq!(header(&head, "mcp-protocol-version"), Some(NEW));
    }

    #[test]
    fn from_2026_07_28_a_tool_call_carries_its_tool_name() {
        let head = posted_head(
            &request(
                "tools/call",
                &json!({"name": "instances_list", "arguments": {}}),
            ),
            Some(NEW),
        );

        assert_eq!(header(&head, "mcp-method"), Some("tools/call"));
        assert_eq!(header(&head, "mcp-name"), Some("instances_list"));
    }

    #[test]
    fn each_naming_method_names_from_its_own_member() {
        for (method, member) in [
            ("tools/call", "name"),
            ("prompts/get", "name"),
            ("resources/read", "uri"),
            ("resources/subscribe", "uri"),
            ("resources/unsubscribe", "uri"),
            ("tasks/get", "taskId"),
            ("tasks/update", "taskId"),
            ("tasks/cancel", "taskId"),
        ] {
            let head = posted_head(
                &request(
                    method,
                    &json!({member: "the target", "other": "not this one"}),
                ),
                Some(NEW),
            );
            assert_eq!(header(&head, "mcp-method"), Some(method));
            assert_eq!(header(&head, "mcp-name"), Some("the target"), "{method}");
        }
    }

    #[test]
    fn a_name_that_cannot_ride_a_header_is_base64_wrapped() {
        // Non-ASCII, a leading space, and a value that already looks encoded.
        for (name, wrapped) in [
            ("recherche-été", "=?base64?cmVjaGVyY2hlLcOpdMOp?="),
            (" leading", "=?base64?IGxlYWRpbmc=?="),
            ("=?base64?x?=", "=?base64?PT9iYXNlNjQ/eD89?="),
        ] {
            let head = posted_head(&request("tools/call", &json!({"name": name})), Some(NEW));
            assert_eq!(header(&head, "mcp-method"), Some("tools/call"));
            assert_eq!(header(&head, "mcp-name"), Some(wrapped), "{name:?}");
        }
    }

    #[test]
    fn a_name_that_is_not_a_string_is_not_sent() {
        for params in [
            json!({"arguments": {}}),
            json!({"name": 5}),
            json!({"name": null}),
        ] {
            let head = posted_head(&request("tools/call", &params), Some(NEW));
            assert_eq!(header(&head, "mcp-method"), Some("tools/call"));
            assert_eq!(header(&head, "mcp-name"), None, "{params}");
        }
    }

    #[test]
    fn an_empty_name_is_an_empty_header_as_rmcp_sends_it() {
        let head = posted_head(&request("tools/call", &json!({"name": ""})), Some(NEW));

        assert_eq!(header(&head, "mcp-method"), Some("tools/call"));
        assert_eq!(header(&head, "mcp-name"), Some(""));
    }

    #[test]
    fn before_2026_07_28_no_method_headers_are_sent() {
        let head = posted_head(
            &request("tools/call", &json!({"name": "instances_list"})),
            Some("2025-11-25"),
        );

        assert_eq!(header(&head, "mcp-protocol-version"), Some("2025-11-25"));
        assert_eq!(header(&head, "mcp-method"), None);
        assert_eq!(header(&head, "mcp-name"), None);
    }

    #[test]
    fn without_a_version_no_method_headers_are_sent() {
        let head = posted_head(
            &request("tools/call", &json!({"name": "instances_list"})),
            None,
        );

        assert_eq!(header(&head, "mcp-protocol-version"), None);
        assert_eq!(header(&head, "mcp-method"), None);
        assert_eq!(header(&head, "mcp-name"), None);
    }

    #[test]
    fn a_response_carries_no_method_headers() {
        let response = r#"{ "jsonrpc": "2.0", "id": 1, "result": { "marker": "ok" } }"#;
        let head = posted_head(response, Some(NEW));

        assert_eq!(header(&head, "mcp-protocol-version"), Some(NEW));
        assert_eq!(header(&head, "mcp-method"), None);
        assert_eq!(header(&head, "mcp-name"), None);
    }

    #[test]
    fn a_body_that_is_not_an_object_carries_no_method_headers_and_rides_as_it_is() {
        let head = posted_head("[1]", Some(NEW));

        assert_eq!(header(&head, "mcp-protocol-version"), Some(NEW));
        assert_eq!(header(&head, "mcp-method"), None);
        assert_eq!(header(&head, "mcp-name"), None);
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
        // A lone JSON scalar, or an object that is not a JSON-RPC message, is none either.
        for body in ["42", r#"{"n": 1}"#] {
            let server = script(vec![respond_raw("200 OK", body)]);
            let reply = client(&server)
                .post(&Token::new(TOKEN), BODY, None)
                .unwrap();
            assert!(reply.messages.is_empty(), "{body}");
        }
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
