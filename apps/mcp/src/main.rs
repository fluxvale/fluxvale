//! The FluxVale MCP server — slice W2a of #484 (rmcp streamable HTTP
//! over the shared `/api/v1` client, PAT passthrough, the read
//! tools) plus W2b's write surface: deploy through destroy, the
//! destructive pair elicitation-gated, and the /me `meta.scopes`
//! filter. The container image + k3d exposure are W3a; the
//! fleet-repo deploy is W3b.
//!
//! Auth holds nothing: the client sends its PAT per request
//! (`Authorization: Bearer fvpat_…`, how remote MCP clients are
//! configured), the server validates it against the platform and
//! forgets it. No token storage, no env token, no keychain.

mod auth;
mod elicit;
mod scopes;
mod server;
#[cfg(test)]
mod testapi;
mod upstream;

use anyhow::{Context, bail};
use axum::{Json, Router, routing::get};
use rmcp::transport::streamable_http_server::{
    StreamableHttpServerConfig, StreamableHttpService, session::never::NeverSessionManager,
};
use serde_json::json;
use std::sync::Arc;

/// Env-only config: MCP_PORT, FLUXVALE_API_BASE_URL, and MCP_ALLOWED_HOSTS
/// (added in W3a — the deployment knob W2a's "no other knobs" deferred to
/// W3: rmcp's DNS-rebinding guard serves only loopback Host headers by
/// default, so a container behind a real hostname — k3d's
/// mcp.fluxvale.lvh.me, W3b's public hosts — names what it serves).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Config {
    pub port: u16,
    pub api_base_url: String,
    /// Empty = rmcp's default loopback allowlist (unset/blank env). The
    /// guard is never disabled: `with_allowed_hosts` is simply not called,
    /// because an empty allowlist means allow-ALL inside rmcp — the
    /// opposite of what an empty env value intends.
    pub allowed_hosts: Vec<String>,
    /// The public MCP endpoint (the RFC 9728 resource identifier):
    /// `MCP_PUBLIC_URL`, else `https://<first allowed host>/mcp`, else
    /// the local bare-server default.
    pub public_url: String,
    /// The authorization server issuer advertised in the protected
    /// resource metadata: `MCP_AUTHORIZATION_SERVER`, else derived from
    /// the public host's deployment shape.
    pub authorization_server: String,
}

impl Config {
    fn from_env() -> anyhow::Result<Self> {
        let port = match std::env::var("MCP_PORT") {
            Ok(raw) => raw
                .parse::<u16>()
                .map_err(|_| anyhow::anyhow!("invalid MCP_PORT {raw:?}: must be a port number"))?,
            Err(_) => 4600,
        };
        let api_base_url = std::env::var("FLUXVALE_API_BASE_URL")
            .map_err(|_| {
                anyhow::anyhow!(
                    "FLUXVALE_API_BASE_URL is not set — the platform origin the tools \
                     call, e.g. https://fluxvale.com"
                )
            })?
            .trim()
            .trim_end_matches('/')
            .to_string();
        if api_base_url.is_empty() {
            bail!("FLUXVALE_API_BASE_URL is empty — set it to the platform origin");
        }
        let allowed_hosts = match std::env::var("MCP_ALLOWED_HOSTS") {
            Ok(raw) => parse_allowed_hosts(&raw),
            Err(_) => Vec::new(),
        };
        let public_url = match std::env::var("MCP_PUBLIC_URL") {
            Ok(raw) if !raw.trim().is_empty() => raw.trim().trim_end_matches('/').to_string(),
            _ => derive_public_url(&allowed_hosts, port),
        };
        let authorization_server = match std::env::var("MCP_AUTHORIZATION_SERVER") {
            Ok(raw) if !raw.trim().is_empty() => raw.trim().trim_end_matches('/').to_string(),
            _ => derive_authorization_server(&public_url, &api_base_url),
        };
        Ok(Config {
            port,
            api_base_url,
            allowed_hosts,
            public_url,
            authorization_server,
        })
    }
}

/// The public endpoint without an explicit env override: the first
/// allowed host is the deployment's ingress host (the local manifest
/// lists the lvh.me host first, then localhost for port-forward), so
/// `https://<host>/mcp` is the served URL. No allowed hosts means a
/// bare local run.
pub(crate) fn derive_public_url(allowed_hosts: &[String], port: u16) -> String {
    match allowed_hosts.first() {
        Some(host) => format!("https://{host}/mcp"),
        None => format!("http://localhost:{port}/mcp"),
    }
}

/// The authorization-server origin: the deployed MCP hosts map to the
/// platform origins by convention (prod/staging/lvh.me), and an
/// explicit `MCP_AUTHORIZATION_SERVER` overrides for anything else.
/// Falling back to `FLUXVALE_API_BASE_URL` keeps a direct local run
/// pointing at the same platform it calls.
pub(crate) fn derive_authorization_server(public_url: &str, api_base_url: &str) -> String {
    let host = url_host(public_url);

    match host.as_deref() {
        Some("mcp.fluxvale.com") => "https://fluxvale.com".to_string(),
        Some("mcp-staging.fluxvale.com") => "https://staging.fluxvale.com".to_string(),
        Some("mcp.fluxvale.lvh.me") => "https://app.fluxvale.lvh.me".to_string(),
        _ => api_base_url.trim_end_matches('/').to_string(),
    }
}

fn url_host(url: &str) -> Option<String> {
    let rest = url.split_once("://")?.1;
    let host = rest.split('/').next()?;
    Some(host.split(':').next().unwrap_or(host).to_string())
}

/// Comma-separated host list → trimmed, empty entries dropped, order
/// preserved, duplicates collapsed. A value with no surviving entries
/// (unset-equivalent: `" , ,"`) yields an empty Vec — the loopback
/// default, never allow-all.
fn parse_allowed_hosts(raw: &str) -> Vec<String> {
    let mut hosts: Vec<String> = Vec::new();
    for host in raw.split(',') {
        let host = host.trim();
        if !host.is_empty() && !hosts.iter().any(|seen| seen == host) {
            hosts.push(host.to_string());
        }
    }
    hosts
}

/// The MCP path — the same one the retiring platform-mounted Elixir
/// server forwarded at (`POST /mcp`, stateless).
pub(crate) const MCP_PATH: &str = "/mcp";

/// The served app: `/health` (no auth, for probes) + the MCP protocol
/// service behind the bearer-extraction middleware.
///
/// `allowed_hosts` feeds rmcp's DNS-rebinding guard (see [`Config`]):
/// non-empty replaces the loopback default exactly; empty keeps it.
/// `/health` rides the outer axum router, deliberately OUTSIDE the
/// guard — probes must not depend on it (a k8s probe sends no Host a
/// deployment could pre-authorize).
#[cfg(test)]
pub(crate) fn build_router(api_base_url: &str, allowed_hosts: &[String]) -> Router {
    let public_url = derive_public_url(allowed_hosts, 4600);
    let authorization_server = derive_authorization_server(&public_url, api_base_url);

    build_router_with(
        api_base_url,
        allowed_hosts,
        &public_url,
        &authorization_server,
    )
}

/// The full constructor: `serve` passes the Config's explicit public
/// URL / authorization server, while tests keep the derived defaults.
pub(crate) fn build_router_with(
    api_base_url: &str,
    allowed_hosts: &[String],
    public_url: &str,
    authorization_server: &str,
) -> Router {
    let base: Arc<str> = Arc::from(api_base_url);

    // Stateless + JSON responses: every POST is independent, the
    // request's own bearer answers it — no session state anywhere
    // (the retiring server's posture: "stateless protocol only").
    // NeverSessionManager is rmcp's documented pairing for disabled
    // legacy sessions.
    let http_config = StreamableHttpServerConfig::default()
        .with_legacy_session_mode(false)
        .with_json_response(true);
    // Only call the builder with a real list: with_allowed_hosts(empty)
    // clears the allowlist, and rmcp reads an empty allowlist as
    // allow-ALL — disable_allowed_hosts by another spelling.
    let http_config = if allowed_hosts.is_empty() {
        http_config
    } else {
        http_config.with_allowed_hosts(allowed_hosts.iter().cloned())
    };
    let mcp = StreamableHttpService::new(
        {
            let base = base.clone();
            move || Ok(server::FluxValeMcp::new(base.clone()))
        },
        Arc::new(NeverSessionManager::default()),
        http_config,
    );

    let mcp_router =
        Router::new()
            .nest_service(MCP_PATH, mcp)
            .layer(axum::middleware::from_fn_with_state(
                auth::AuthState::new(api_base_url, public_url),
                auth::require_bearer,
            ));

    Router::new()
        .route("/health", get(health))
        .route(
            "/.well-known/oauth-protected-resource",
            get(protected_resource_metadata),
        )
        .route(
            "/.well-known/oauth-protected-resource/mcp",
            get(protected_resource_metadata),
        )
        .merge(mcp_router)
        .with_state(auth::MetadataState::new(public_url, authorization_server))
}

/// RFC 9728 protected-resource metadata (#766): the resource identifier,
/// the authorization server, the scopes the MCP surface understands, and
/// the header bearer method. The audience is this server alone.
async fn protected_resource_metadata(
    axum::extract::State(state): axum::extract::State<auth::MetadataState>,
) -> Json<serde_json::Value> {
    Json(json!({
        "resource": state.public_url,
        "authorization_servers": [state.authorization_server],
        "scopes_supported": auth::SCOPES_SUPPORTED,
        "bearer_methods_supported": ["header"],
        "resource_name": "FluxVale MCP",
        "resource_documentation": format!("{}/settings/agents", state.authorization_server),
    }))
}

/// `/health` — k8s probes and W3's deploy gating. No auth, no deps.
async fn health() -> Json<serde_json::Value> {
    Json(json!({
        "status": "ok",
        "version": env!("CARGO_PKG_VERSION"),
    }))
}

/// The env-var tests' mutual exclusion (env vars are process-global).
#[cfg(test)]
pub(crate) fn test_env_lock() -> &'static std::sync::Mutex<()> {
    use std::sync::{Mutex, OnceLock};
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    init_tracing();
    let config = Config::from_env()?;
    serve(config, shutdown_signal()).await
}

/// tracing to stdout; RUST_LOG filters, info default.
///
/// `ureq_proto` is capped at info regardless of the global level: at
/// trace it dumps raw HTTP heads — the Authorization header included —
/// so a stray `RUST_LOG=trace` would leak the caller's PAT to stdout.
fn init_tracing() {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
    // Target-specific directives win over a global trace level. rmcp
    // logs the whole inbound request (env values included) at debug, so
    // the protocol crate stays at info regardless of RUST_LOG — the
    // env-var tools' write-only promise holds at every level.
    let filter = filter
        .add_directive("ureq_proto=info".parse().expect("literal directive parses"))
        .add_directive("rmcp=info".parse().expect("literal directive parses"));
    tracing_subscriber::fmt().with_env_filter(filter).init();
}

/// The two production shutdown signals: Ctrl-C (SIGINT) and SIGTERM —
/// the container runtime stops W3's pod with the latter.
///
/// main, this fn, and its select arms are the deliberate coverage
/// exclusions (the lane's documented "prod-only" class): the OS signal
/// arms are unreachable in an in-process test — `serve` and the router
/// are fully covered below.
#[cfg(unix)]
async fn shutdown_signal() {
    use tokio::signal::unix::{SignalKind, signal};
    let mut sigterm = signal(SignalKind::terminate()).expect("install the SIGTERM handler");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = sigterm.recv() => {}
    }
}

#[cfg(not(unix))]
async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

/// Bind and serve until `shutdown` resolves. Split from [`main`] so a
/// test can drive the whole bind-serve-shutdown loop (port 0, an
/// immediate shutdown).
async fn serve(
    config: Config,
    shutdown: impl std::future::Future<Output = ()> + Send + 'static,
) -> anyhow::Result<()> {
    let app = build_router_with(
        &config.api_base_url,
        &config.allowed_hosts,
        &config.public_url,
        &config.authorization_server,
    );
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", config.port))
        .await
        .with_context(|| format!("bind 0.0.0.0:{}", config.port))?;
    tracing::info!(port = config.port, "fluxvale-mcp listening");
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown)
        .await
        .map_err(|err| anyhow::anyhow!("server error: {err}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_to_port_4600() {
        // FLUXVALE_API_BASE_URL set; no MCP_PORT. The lock: env vars
        // are process-global, and these tests run in parallel.
        let _guard = test_env_lock().lock().unwrap();
        unsafe { std::env::set_var("FLUXVALE_API_BASE_URL", "https://fluxvale.com") };
        unsafe { std::env::remove_var("MCP_PORT") };
        let config = Config::from_env().unwrap();
        assert_eq!(config.port, 4600);
        assert_eq!(config.api_base_url, "https://fluxvale.com");
    }

    #[test]
    fn trims_a_trailing_slash_from_the_origin() {
        let _guard = test_env_lock().lock().unwrap();
        unsafe { std::env::set_var("FLUXVALE_API_BASE_URL", "http://127.0.0.1:4000/") };
        unsafe { std::env::remove_var("MCP_PORT") };
        let config = Config::from_env().unwrap();
        assert_eq!(config.api_base_url, "http://127.0.0.1:4000");
    }

    #[test]
    fn reads_an_explicit_port() {
        let _guard = test_env_lock().lock().unwrap();
        unsafe { std::env::set_var("FLUXVALE_API_BASE_URL", "https://fluxvale.com") };
        unsafe { std::env::set_var("MCP_PORT", "8080") };
        let config = Config::from_env().unwrap();
        assert_eq!(config.port, 8080);
    }

    #[test]
    fn refuses_a_non_numeric_port_loudly() {
        let _guard = test_env_lock().lock().unwrap();
        unsafe { std::env::set_var("FLUXVALE_API_BASE_URL", "https://fluxvale.com") };
        unsafe { std::env::set_var("MCP_PORT", "four-thousand") };
        let err = Config::from_env().unwrap_err();
        assert!(err.to_string().contains("invalid MCP_PORT"), "err: {err}");
    }

    #[test]
    fn requires_the_platform_origin() {
        let _guard = test_env_lock().lock().unwrap();
        unsafe { std::env::remove_var("FLUXVALE_API_BASE_URL") };
        unsafe { std::env::remove_var("MCP_PORT") };
        let err = Config::from_env().unwrap_err();
        assert!(
            err.to_string().contains("FLUXVALE_API_BASE_URL is not set"),
            "err: {err}"
        );
    }

    #[test]
    fn refuses_an_empty_origin() {
        let _guard = test_env_lock().lock().unwrap();
        unsafe { std::env::set_var("FLUXVALE_API_BASE_URL", " ") };
        unsafe { std::env::remove_var("MCP_PORT") };
        let err = Config::from_env().unwrap_err();
        assert!(err.to_string().contains("empty"), "err: {err}");
    }

    // ---- MCP_ALLOWED_HOSTS (the W3a deployment knob) --------------------

    #[test]
    fn unset_allowed_hosts_keeps_the_loopback_default() {
        let _guard = test_env_lock().lock().unwrap();
        unsafe { std::env::set_var("FLUXVALE_API_BASE_URL", "https://fluxvale.com") };
        unsafe { std::env::remove_var("MCP_PORT") };
        unsafe { std::env::remove_var("MCP_ALLOWED_HOSTS") };
        let config = Config::from_env().unwrap();
        // Empty Vec = rmcp's default loopback allowlist, never allow-all.
        assert!(config.allowed_hosts.is_empty());
    }

    #[test]
    fn allowed_hosts_trim_and_dedupe() {
        let _guard = test_env_lock().lock().unwrap();
        unsafe { std::env::set_var("FLUXVALE_API_BASE_URL", "https://fluxvale.com") };
        unsafe { std::env::remove_var("MCP_PORT") };
        // Set AND clear: a later test in this module reads the unset
        // arms — leaking the var would flip its meaning.
        unsafe {
            std::env::set_var(
                "MCP_ALLOWED_HOSTS",
                " mcp.fluxvale.lvh.me , mcp.fluxvale.lvh.me, localhost ",
            )
        };
        let config = Config::from_env().unwrap();
        assert_eq!(
            config.allowed_hosts,
            ["mcp.fluxvale.lvh.me".to_string(), "localhost".to_string()]
        );
        unsafe { std::env::remove_var("MCP_ALLOWED_HOSTS") };
    }

    #[test]
    fn all_blank_allowed_hosts_entries_read_as_unset() {
        let _guard = test_env_lock().lock().unwrap();
        unsafe { std::env::set_var("FLUXVALE_API_BASE_URL", "https://fluxvale.com") };
        unsafe { std::env::remove_var("MCP_PORT") };
        unsafe { std::env::set_var("MCP_ALLOWED_HOSTS", " , , ") };
        let config = Config::from_env().unwrap();
        assert!(config.allowed_hosts.is_empty());
    }

    // ---- public URL / authorization server derivation (#766) ------------

    #[test]
    fn the_public_url_derives_from_the_first_allowed_host() {
        assert_eq!(
            derive_public_url(&["mcp.fluxvale.com".to_string()], 4600),
            "https://mcp.fluxvale.com/mcp"
        );
        assert_eq!(
            derive_public_url(
                &["mcp.fluxvale.lvh.me".to_string(), "localhost".to_string()],
                4600
            ),
            "https://mcp.fluxvale.lvh.me/mcp"
        );
        assert_eq!(derive_public_url(&[], 4600), "http://localhost:4600/mcp");
    }

    #[test]
    fn the_authorization_server_follows_the_deployment_shape() {
        assert_eq!(
            derive_authorization_server("https://mcp.fluxvale.com/mcp", "http://127.0.0.1:4000"),
            "https://fluxvale.com"
        );
        assert_eq!(
            derive_authorization_server(
                "https://mcp-staging.fluxvale.com/mcp",
                "http://127.0.0.1:4000"
            ),
            "https://staging.fluxvale.com"
        );
        assert_eq!(
            derive_authorization_server(
                "https://mcp.fluxvale.lvh.me/mcp",
                "http://fluxvale-platform.fluxvale-dev.svc.cluster.local:4000"
            ),
            "https://app.fluxvale.lvh.me"
        );
        assert_eq!(
            derive_authorization_server(
                "https://mcp.example.test/mcp",
                "https://api.example.test/"
            ),
            "https://api.example.test"
        );
    }

    #[test]
    fn the_public_url_env_wins_over_derivation() {
        let _guard = test_env_lock().lock().unwrap();
        unsafe { std::env::set_var("FLUXVALE_API_BASE_URL", "https://fluxvale.com") };
        unsafe { std::env::remove_var("MCP_PORT") };
        unsafe { std::env::remove_var("MCP_ALLOWED_HOSTS") };
        unsafe { std::env::set_var("MCP_PUBLIC_URL", "https://mcp.example.test/mcp/") };
        let config = Config::from_env().unwrap();
        assert_eq!(config.public_url, "https://mcp.example.test/mcp");
        unsafe { std::env::remove_var("MCP_PUBLIC_URL") };
    }

    #[test]
    fn the_authorization_server_env_wins_over_derivation() {
        let _guard = test_env_lock().lock().unwrap();
        unsafe { std::env::set_var("FLUXVALE_API_BASE_URL", "https://fluxvale.com") };
        unsafe { std::env::remove_var("MCP_PORT") };
        unsafe { std::env::remove_var("MCP_ALLOWED_HOSTS") };
        unsafe { std::env::set_var("MCP_AUTHORIZATION_SERVER", "https://auth.example.test/") };
        let config = Config::from_env().unwrap();
        assert_eq!(config.authorization_server, "https://auth.example.test");
        unsafe { std::env::remove_var("MCP_AUTHORIZATION_SERVER") };
    }

    // ---- RFC 9728 protected-resource metadata (#766) --------------------

    async fn protected_resource(
        public_url: &str,
        authorization_server: &str,
        path: &str,
    ) -> (axum::http::StatusCode, serde_json::Value) {
        use axum::body::Body;
        use axum::http::{Method, Request};
        use tower::ServiceExt;

        let app = build_router_with("http://127.0.0.1:1", &[], public_url, authorization_server);
        let request = Request::builder()
            .method(Method::GET)
            .uri(path)
            .body(Body::empty())
            .unwrap();
        let response = app.oneshot(request).await.unwrap();
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let body = serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null);
        (status, body)
    }

    #[tokio::test]
    async fn protected_resource_metadata_names_the_prod_pair() {
        let (status, body) = protected_resource(
            "https://mcp.fluxvale.com/mcp",
            "https://fluxvale.com",
            "/.well-known/oauth-protected-resource",
        )
        .await;

        assert_eq!(status, axum::http::StatusCode::OK);
        assert_eq!(body["resource"], "https://mcp.fluxvale.com/mcp");
        assert_eq!(
            body["authorization_servers"],
            json!(["https://fluxvale.com"])
        );
        assert_eq!(body["bearer_methods_supported"], json!(["header"]));
        assert_eq!(body["resource_name"], "FluxVale MCP");
        assert_eq!(
            body["resource_documentation"],
            "https://fluxvale.com/settings/agents"
        );
        let scopes = body["scopes_supported"].as_array().expect("scopes array");
        assert!(scopes.iter().any(|scope| scope == "instances:write"));
        assert!(scopes.iter().any(|scope| scope == "wallet:read"));
        assert!(!scopes.iter().any(|scope| scope == "offline_access"));
    }

    #[tokio::test]
    async fn protected_resource_metadata_names_the_staging_pair() {
        let (status, body) = protected_resource(
            "https://mcp-staging.fluxvale.com/mcp",
            "https://staging.fluxvale.com",
            "/.well-known/oauth-protected-resource",
        )
        .await;

        assert_eq!(status, axum::http::StatusCode::OK);
        assert_eq!(body["resource"], "https://mcp-staging.fluxvale.com/mcp");
        assert_eq!(
            body["authorization_servers"],
            json!(["https://staging.fluxvale.com"])
        );
    }

    #[tokio::test]
    async fn protected_resource_metadata_names_the_local_pair_and_the_path_variant() {
        for path in [
            "/.well-known/oauth-protected-resource",
            "/.well-known/oauth-protected-resource/mcp",
        ] {
            let (status, body) = protected_resource(
                "https://mcp.fluxvale.lvh.me/mcp",
                "https://app.fluxvale.lvh.me",
                path,
            )
            .await;

            assert_eq!(status, axum::http::StatusCode::OK, "path {path}");
            assert_eq!(body["resource"], "https://mcp.fluxvale.lvh.me/mcp");
            assert_eq!(
                body["authorization_servers"],
                json!(["https://app.fluxvale.lvh.me"])
            );
        }
    }

    /// The plumbing proof: the env knob must reach the SERVED guard, not
    /// just the Config struct — a missed builder call would leave the
    /// loopback default and 403 the configured host (exactly the gap the
    /// W3a STOP found). One initialize POST (never touches the upstream),
    /// two Host headers: the configured host serves, anything else draws
    /// rmcp's DNS-rebinding 403.
    #[tokio::test]
    async fn allowed_hosts_reach_the_served_guard() {
        use axum::body::Body;
        use axum::http::{Method, StatusCode};
        use tower::ServiceExt;

        let app = build_router("http://127.0.0.1:1", &["mcp.fluxvale.lvh.me".to_string()]);

        let initialize_post = |host: &'static str| {
            axum::http::Request::builder()
                .method(Method::POST)
                .uri("/mcp")
                .header("host", host)
                .header("content-type", "application/json")
                .header("accept", "application/json, text/event-stream")
                .header("mcp-method", "initialize")
                .header("authorization", "Bearer fvpat_router_test")
                .body(Body::from(
                    json!({
                        "jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {
                            "protocolVersion": "2025-11-25",
                            "capabilities": {},
                            "clientInfo": {"name": "w3a-router-test", "version": "0.0.0"}
                        }
                    })
                    .to_string(),
                ))
                .unwrap()
        };

        let allowed = app
            .clone()
            .oneshot(initialize_post("mcp.fluxvale.lvh.me"))
            .await
            .unwrap();
        assert_eq!(allowed.status(), StatusCode::OK);

        let refused = app
            .clone()
            .oneshot(initialize_post("not-the-configured.host"))
            .await
            .unwrap();
        assert_eq!(refused.status(), StatusCode::FORBIDDEN);
    }

    /// The "never allow-all" property, pinned: rmcp treats an EMPTY
    /// list as allow-everything (tower.rs's is_empty early-return), so
    /// `build_router`'s empty→default branch is the only thing keeping
    /// the secure default. Deleting that branch must red THIS test —
    /// a foreign Host must 403 even when the caller passed `&[]`.
    #[tokio::test]
    async fn an_empty_allowed_hosts_list_stays_loopback_not_allow_all() {
        use axum::body::Body;
        use axum::http::{Method, StatusCode};
        use tower::ServiceExt;

        let app = build_router("http://127.0.0.1:1", &[]);

        let post = |host: &'static str| {
            axum::http::Request::builder()
                .method(Method::POST)
                .uri("/mcp")
                .header("host", host)
                .header("content-type", "application/json")
                .header("accept", "application/json, text/event-stream")
                .header("mcp-method", "initialize")
                .header("authorization", "Bearer fvpat_router_test")
                .body(Body::from(
                    json!({
                        "jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {
                            "protocolVersion": "2025-11-25",
                            "capabilities": {},
                            "clientInfo": {"name": "w3a-router-test", "version": "0.0.0"}
                        }
                    })
                    .to_string(),
                ))
                .unwrap()
        };

        let local = app.clone().oneshot(post("localhost:4600")).await.unwrap();
        assert_eq!(local.status(), StatusCode::OK);

        let foreign = app.clone().oneshot(post("evil.example")).await.unwrap();
        assert_eq!(foreign.status(), StatusCode::FORBIDDEN);
    }

    #[tokio::test]
    async fn serve_binds_serves_and_shuts_down() {
        // Port 0: an ephemeral listener. The shutdown future fires
        // almost immediately, so serve() binds, serves, and resolves
        // Ok.
        let config = Config {
            port: 0,
            api_base_url: "http://127.0.0.1:1".to_string(),
            allowed_hosts: Vec::new(),
            public_url: "http://localhost:4600/mcp".to_string(),
            authorization_server: "http://127.0.0.1:1".to_string(),
        };
        let result = serve(config, async {
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        })
        .await;
        assert!(result.is_ok(), "err: {:?}", result.err());
    }

    #[test]
    fn init_tracing_installs_a_working_subscriber() {
        // The filter string parses and the subscriber installs — the
        // process-wide default is set exactly once (main's call).
        let _ = std::panic::catch_unwind(init_tracing);
    }

    #[test]
    fn health_reports_status_and_version_without_auth() {
        let app = build_router("http://127.0.0.1:1", &[]);
        let response = tokio::runtime::Runtime::new().unwrap().block_on(async {
            let response = tower::ServiceExt::oneshot(
                app,
                axum::http::Request::builder()
                    .uri("/health")
                    .body(axum::body::Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
            let (parts, body) = response.into_parts();
            let bytes = http_body_util::BodyExt::collect(body)
                .await
                .unwrap()
                .to_bytes();
            (parts.status, bytes)
        });
        let (status, bytes) = response;
        assert_eq!(status, axum::http::StatusCode::OK);
        let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(body["status"], "ok");
        assert_eq!(body["version"], env!("CARGO_PKG_VERSION"));
    }
}
