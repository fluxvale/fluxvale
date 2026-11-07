//! The FluxVale MCP server — slice W2a of #484: rmcp streamable HTTP
//! over the shared `/api/v1` client, PAT passthrough, the first five
//! read tools. Write tools, destructive gating, and deployment are
//! W2b/W3.
//!
//! Auth holds nothing: the client sends its PAT per request
//! (`Authorization: Bearer fvpat_…`, how remote MCP clients are
//! configured), the server validates it against the platform and
//! forgets it. No token storage, no env token, no keychain.

mod auth;
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

/// Env-only config (the W2a brief): MCP_PORT + FLUXVALE_API_BASE_URL.
/// No other knobs — deployment config is W3's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Config {
    pub port: u16,
    pub api_base_url: String,
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
        Ok(Config { port, api_base_url })
    }
}

/// The MCP path — the same one the retiring platform-mounted Elixir
/// server forwarded at (`POST /mcp`, stateless).
pub(crate) const MCP_PATH: &str = "/mcp";

/// The served app: `/health` (no auth, for probes) + the MCP protocol
/// service behind the bearer-extraction middleware.
pub(crate) fn build_router(api_base_url: &str) -> Router {
    let base: Arc<str> = Arc::from(api_base_url);

    // Stateless + JSON responses: every POST is independent, the
    // request's own bearer answers it — no session state anywhere
    // (the retiring server's posture: "stateless protocol only").
    // NeverSessionManager is rmcp's documented pairing for disabled
    // legacy sessions.
    let mcp = StreamableHttpService::new(
        {
            let base = base.clone();
            move || Ok(server::FluxValeMcp::new(base.clone()))
        },
        Arc::new(NeverSessionManager::default()),
        StreamableHttpServerConfig::default()
            .with_legacy_session_mode(false)
            .with_json_response(true),
    );

    let mcp_router = Router::new()
        .nest_service(MCP_PATH, mcp)
        .layer(axum::middleware::from_fn(auth::require_bearer));

    Router::new()
        .route("/health", get(health))
        .merge(mcp_router)
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
fn init_tracing() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();
}

/// The one production shutdown signal: Ctrl-C. main/init_tracing/
/// this fn are the deliberate coverage exclusions (the lane's
/// documented "prod-only" class): the process entry, the global
/// subscriber install (a second install panics in-process), and the
/// OS signal arm are unreachable in an in-process test — `serve` and
/// the router are fully covered below.
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
    let app = build_router(&config.api_base_url);
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

    #[tokio::test]
    async fn serve_binds_serves_and_shuts_down() {
        // Port 0: an ephemeral listener. The shutdown future fires
        // almost immediately, so serve() binds, serves, and resolves
        // Ok.
        let config = Config {
            port: 0,
            api_base_url: "http://127.0.0.1:1".to_string(),
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
        let app = build_router("http://127.0.0.1:1");
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
