//! Golden-file test for the Terraform import scaffold (#763): a
//! recorded `/api/v1` conversation in, the three files out. The
//! fixtures mirror the platform's response shapes (staging captures plus
//! the committed OpenAPI artifact), with ids and names replaced by stable
//! values — not a hand-invented estate.

use fluxvale_api::{ApiClient, Token, terraform};
use std::collections::HashMap;
use std::io::{Read as _, Write as _};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/terraform");

fn fixture(name: &str) -> String {
    std::fs::read_to_string(format!("{FIXTURES}/{name}"))
        .unwrap_or_else(|err| panic!("read fixture {name}: {err}"))
}

/// A tiny upstream that answers the exact paths discovery calls. A
/// path outside the map answers 404 `{}` (the absent-singleton shape).
struct RecordedApi {
    base_url: String,
    methods: Arc<Mutex<Vec<String>>>,
}

impl RecordedApi {
    fn start(routes: Vec<(&'static str, u16, String)>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let methods = Arc::new(Mutex::new(Vec::new()));
        let captured = methods.clone();
        let routes: HashMap<&'static str, (u16, String)> = routes
            .into_iter()
            .map(|(path, status, body)| (path, (status, body)))
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
                let request_line = head.lines().next().unwrap_or_default();
                let mut parts = request_line.split(' ');
                let method = parts.next().unwrap_or_default().to_string();
                let path = parts.next().unwrap_or_default();
                captured.lock().unwrap().push(method);
                let (status, body) = routes.get(path).cloned().unwrap_or((404, "{}".to_string()));
                let reason = match status {
                    200 => "OK",
                    404 => "Not Found",
                    _ => "Internal Server Error",
                };
                let response = format!(
                    "HTTP/1.1 {status} {reason}\r\nContent-Type: application/vnd.api+json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.flush();
            }
        });
        RecordedApi {
            base_url: format!("http://{addr}"),
            methods,
        }
    }

    fn methods(&self) -> Vec<String> {
        self.methods.lock().unwrap().clone()
    }
}

#[test]
fn the_recorded_estate_renders_the_golden_scaffold() {
    let api = RecordedApi::start(vec![
        ("/api/v1/organizations", 200, fixture("organizations.json")),
        (
            "/api/v1/instances?fields[instance]=id,name,slug,organization_id,status",
            200,
            fixture("instances.json"),
        ),
        (
            "/api/v1/instances/i-web/backup-setting",
            200,
            fixture("backup-setting.json"),
        ),
        (
            "/api/v1/instances/i-web/pocket-id-wiring",
            200,
            fixture("pocket-id-wiring.json"),
        ),
        (
            "/api/v1/organizations/org-acme/access-gateway",
            200,
            fixture("access-gateway.json"),
        ),
        (
            "/api/v1/organizations/org-acme/access-domains",
            200,
            fixture("access-domains.json"),
        ),
    ]);
    let client = ApiClient::new(&api.base_url, Token::new("fvpat_testtoken"));
    let bundle = terraform::bundle_with(&client, "acme", "https://fluxvale.com").unwrap();
    assert_eq!(bundle.organization, "acme");

    if std::env::var_os("PRINT_GOLDEN").is_some() {
        for file in &bundle.files {
            println!("===== {}\n{}", file.name, file.contents);
        }
    }

    for (name, golden) in [
        ("versions.tf", "versions.tf.golden"),
        ("imports.tf", "imports.tf.golden"),
        ("README.md", "README.md.golden"),
    ] {
        let file = bundle
            .file(name)
            .unwrap_or_else(|| panic!("missing {name}"));
        assert_eq!(
            file.contents,
            fixture(golden),
            "{name} drifted from its golden file"
        );
    }
}

#[test]
fn an_unknown_org_lists_the_memberships_and_renders_nothing() {
    let api = RecordedApi::start(vec![(
        "/api/v1/organizations",
        200,
        fixture("organizations.json"),
    )]);
    let client = ApiClient::new(&api.base_url, Token::new("fvpat_testtoken"));
    let error = terraform::bundle(&client, "ghost").unwrap_err().to_string();
    assert!(
        error.contains("no organization with id or slug \"ghost\""),
        "{error}"
    );
    assert!(error.contains("acme (org-acme)"), "{error}");
}

#[test]
fn a_missing_org_id_is_loud_instead_of_an_empty_estate() {
    let api = RecordedApi::start(vec![
        ("/api/v1/organizations", 200, fixture("organizations.json")),
        (
            "/api/v1/instances?fields[instance]=id,name,slug,organization_id,status",
            200,
            r#"{"data":[{"type":"instance","id":"i-x","attributes":{"name":"x","slug":"x","status":"running"}}]}"#
                .to_string(),
        ),
    ]);
    let client = ApiClient::new(&api.base_url, Token::new("fvpat_testtoken"));
    let error = terraform::bundle(&client, "acme").unwrap_err().to_string();
    assert!(error.contains("did not echo organization_id"), "{error}");
    assert!(error.contains("i-x"), "{error}");
}

#[test]
fn discovery_never_writes() {
    // Every upstream call in the recorded conversation is a GET: the
    // scaffold is read-shaped by construction, and a mutation would
    // need a new fixture route and a visible method here.
    let api = RecordedApi::start(vec![
        ("/api/v1/organizations", 200, fixture("organizations.json")),
        (
            "/api/v1/instances?fields[instance]=id,name,slug,organization_id,status",
            200,
            fixture("instances.json"),
        ),
        (
            "/api/v1/organizations/org-acme/access-domains",
            200,
            fixture("access-domains.json"),
        ),
    ]);
    let client = ApiClient::new(&api.base_url, Token::new("fvpat_testtoken"));
    let _ = terraform::bundle(&client, "acme").unwrap();
    assert!(!api.methods().is_empty());
    assert!(
        api.methods().iter().all(|method| method == "GET"),
        "non-GET call: {:?}",
        api.methods()
    );
}
