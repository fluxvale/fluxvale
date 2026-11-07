//! The canned upstream (`#[cfg(test)]` only): a real TcpListener
//! answering per-path JSON:API documents, capturing request heads —
//! the CLI's tiny-test-server pattern, shared by the upstream unit
//! tests and the handler end-to-end tests.

#![allow(dead_code)] // per-test fixtures; not every route is served by every test

use std::{
    io::{Read as _, Write as _},
    net::TcpListener,
    sync::{Arc, Mutex},
};

/// A running canned upstream. `base_url` is what the server under test
/// points at; `heads` captures one raw request head per upstream call.
pub(crate) struct CannedApi {
    pub base_url: String,
    heads: Arc<Mutex<Vec<String>>>,
}

impl CannedApi {
    /// The captured request head of the Nth upstream call (0-based).
    pub(crate) fn head(&self, index: usize) -> String {
        self.heads.lock().unwrap()[index].clone()
    }

    pub(crate) fn head_count(&self) -> usize {
        self.heads.lock().unwrap().len()
    }
}

/// Serve canned `(path, status, body)` responses until dropped. A path
/// with no entry answers 404 `{}` — the "route doesn't exist" shape.
pub(crate) fn serve(routes: &[(&str, u16, String)]) -> CannedApi {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let heads = Arc::new(Mutex::new(Vec::new()));
    let captured = heads.clone();
    let routes: Vec<(String, u16, String)> = routes
        .iter()
        .map(|(path, status, body)| ((*path).to_string(), *status, body.clone()))
        .collect();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { break };
            let mut head = String::new();
            let mut buf = [0u8; 4096];
            while !head.contains("\r\n\r\n") {
                let read = stream.read(&mut buf).unwrap();
                if read == 0 {
                    break;
                }
                head.push_str(&String::from_utf8_lossy(&buf[..read]));
            }
            captured.lock().unwrap().push(head.clone());
            let path = head
                .lines()
                .next()
                .and_then(|line| line.split(' ').nth(1))
                .unwrap_or("")
                .to_string();
            let response = match routes.iter().find(|(route_path, _, _)| path == *route_path) {
                Some((_, status, body)) => format!(
                    "HTTP/1.1 {}\r\nContent-Type: application/vnd.api+json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    status_line(*status),
                    body.len(),
                    body
                ),
                None => {
                    "HTTP/1.1 404 Not Found\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
                        .to_string()
                }
            };
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.flush();
        }
    });
    CannedApi {
        base_url: format!("http://{addr}"),
        heads,
    }
}

fn status_line(status: u16) -> &'static str {
    match status {
        200 => "200 OK",
        401 => "401 Unauthorized",
        403 => "403 Forbidden",
        404 => "404 Not Found",
        429 => "429 Too Many Requests",
        _ => "500 Internal Server Error",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_connection_that_dies_mid_head_does_not_take_the_server_down() {
        let server = serve(&[("/api/v1/me", 200, "{}".to_string())]);
        let addr = server.base_url.trim_start_matches("http://").to_string();
        // Write half a request head, then close — the server's read
        // loop hits EOF and moves on to the next connection.
        let mut stream = std::net::TcpStream::connect(&addr).unwrap();
        stream.write_all(b"GET /api/v1/me HTTP/1.1\r\n").unwrap();
        drop(stream);
        // The server still answers a fresh client.
        let mut stream = std::net::TcpStream::connect(&addr).unwrap();
        stream
            .write_all(b"GET /api/v1/me HTTP/1.1\r\nHost: x\r\n\r\n")
            .unwrap();
        let mut head = String::new();
        let mut buf = [0u8; 4096];
        // The `read == 0` break below is the loop's EOF guard — the
        // deliberate coverage exclusion here (race-window class): this
        // server always answers a full head, so the client never sees
        // a premature close on the read side.
        while !head.contains("\r\n\r\n") {
            let read = std::io::Read::read(&mut stream, &mut buf).unwrap();
            if read == 0 {
                break;
            }
            head.push_str(&String::from_utf8_lossy(&buf[..read]));
        }
        assert!(head.starts_with("HTTP/1.1 200 OK"), "got: {head}");
    }
}
