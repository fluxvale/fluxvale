//! The MCP surface: the [`FluxValeMcp`] handler — the five read
//! tools, the initialize gate (GET /me, protocol-refuse a dead
//! token), and the scope-filtered tools/list (fresh /me + the
//! platform's own probes on every list, no caching). Descriptions are
//! agent-facing copy in the retiring Elixir server's register.

use rmcp::{
    ErrorData, RoleServer, ServerHandler,
    handler::server::{tool::ToolRouter, wrapper::Parameters},
    model::{
        CallToolResult, ContentBlock, DiscoverResult, ErrorCode, InitializeRequestParams,
        InitializeResult, ListToolsResult, PaginatedRequestParams, ServerCapabilities,
        ServerConfig, Tool,
    },
    service::RequestContext,
    tool, tool_handler, tool_router,
};
use std::{borrow::Cow, sync::Arc};

use crate::{auth::McpAuth, scopes, upstream};
use fluxvale_api::{ApiError, Token};

/// The agent-facing instructions: who this server serves, and that
/// the token decides what appears in tools/list.
const INSTRUCTIONS: &str = "FluxVale as tools for AI agents: reads over your \
account — your identity, the deployable app catalog, your instances' \
lifecycle. Policies are enforced exactly as over the HTTP API: you only \
ever see your own data, and tools/list only ever offers what your \
token's scopes cover.";

pub(crate) struct FluxValeMcp {
    /// The platform origin every tool call rides to. The server holds
    /// nothing else — no token, no session state.
    api_base_url: Arc<str>,
    tool_router: ToolRouter<FluxValeMcp>,
}

/// `apps_show`'s input.
#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub(crate) struct AppsShowParams {
    /// The app's URL slug (from `apps_list`).
    pub slug: String,
}

/// `instances_status`'s input — no id means the verbose list.
#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub(crate) struct InstanceStatusParams {
    /// The instance's id (from `instances_list`). Omit for the verbose
    /// list of all your instances.
    pub id: Option<String>,
}

#[tool_router]
impl FluxValeMcp {
    pub(crate) fn new(api_base_url: Arc<str>) -> Self {
        Self {
            api_base_url,
            tool_router: Self::tool_router(),
        }
    }

    /// The request's own bearer, lifted by the middleware (rmcp's
    /// documented pattern: the injected HTTP parts carry axum
    /// extensions). Per-request by design — the server stores nothing.
    fn token(&self, context: &RequestContext<RoleServer>) -> Result<Token, ErrorData> {
        let parts = context.extensions.get::<axum::http::request::Parts>();
        let auth = parts.and_then(|parts| parts.extensions.get::<McpAuth>().map(|McpAuth(t)| t));
        token_from_parts(parts, auth)
    }

    #[tool(
        description = "The identity this token carries: user id, email, platform \
role, username, and the organizations the user belongs to (id, slug and \
name each). Use it first to see who you are and to learn the ids the \
other tools take."
    )]
    async fn whoami(
        &self,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(upstream::whoami(self.api_base_url.clone(), token).await)
    }

    #[tool(
        description = "The deployable app catalog: one entry per app — id, name, \
slug, tagline, description, icon/source/docs URLs, file-access flag, \
category. Slugs from here are what `apps_show` takes."
    )]
    async fn apps_list(
        &self,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(upstream::apps_list(self.api_base_url.clone(), token).await)
    }

    #[tool(
        description = "One catalog app by its URL slug: name, tagline, description, \
icon/source/docs URLs, file-access flag. Get the slug from `apps_list`. \
Errors when no app carries the slug."
    )]
    async fn apps_show(
        &self,
        Parameters(AppsShowParams { slug }): Parameters<AppsShowParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(upstream::apps_show(self.api_base_url.clone(), token, slug).await)
    }

    #[tool(
        description = "Your instances: one entry per deployed app — id, name, slug, \
namespace, lifecycle status, exposure, always-on flag, deployed-at. The \
ids are what `instances_status` takes."
    )]
    async fn instances_list(
        &self,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(upstream::instances_list(self.api_base_url.clone(), token).await)
    }

    #[tool(
        description = "One instance's full detail by id: lifecycle status, exposure, \
allocation (cpu/memory/storage), image, port, healthcheck path, \
file-access flag, deployed-at. Get the id from `instances_list`. Omit \
the id to get the verbose list of all your instances instead. Errors \
when the id is not one of your instances."
    )]
    async fn instances_status(
        &self,
        Parameters(InstanceStatusParams { id }): Parameters<InstanceStatusParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(upstream::instances_status(self.api_base_url.clone(), token, id).await)
    }
}

/// [`FluxValeMcp::token`]'s arms, pure over the pieces the transport
/// hands the handler. The None arms are defense in depth — the
/// middleware guarantees both in the served shape.
fn token_from_parts(
    parts: Option<&axum::http::request::Parts>,
    auth: Option<&Token>,
) -> Result<Token, ErrorData> {
    parts.ok_or_else(|| {
        ErrorData::internal_error(
            "no HTTP context on the request — the bearer middleware did not run",
            None,
        )
    })?;
    auth.cloned().ok_or_else(|| {
        auth_error(
            "no bearer token on the request — configure this MCP \
             server's Authorization header"
                .to_string(),
        )
    })
}

/// A read's row(s) as structured content; any upstream refusal is a
/// TOOL error carrying the message verbatim — never a protocol error,
/// never scrubbed.
fn tool_result(row: Result<serde_json::Value, String>) -> Result<CallToolResult, ErrorData> {
    match row {
        Ok(value) => Ok(CallToolResult::structured(value)),
        Err(message) => Ok(CallToolResult::error(vec![ContentBlock::text(message)])),
    }
}

/// The protocol-level authentication error: the client must
/// reconfigure its token. The API's own words ride inside.
fn auth_error(message: String) -> ErrorData {
    ErrorData::new(
        ErrorCode::INVALID_REQUEST,
        Cow::Owned(format!("authentication failed: {message}")),
        None,
    )
}

/// Upstream is transiently unusable (429, 5xx, transport) — a protocol
/// error, verbatim line inside, no retries.
fn upstream_error(message: String) -> ErrorData {
    ErrorData::internal_error(format!("the FluxVale API is unavailable: {message}"), None)
}

/// The /me gate's error mapping (initialize and discover): 401/403 are
/// AUTH — the client must reconfigure its token; anything else is
/// upstream, verbatim.
fn gate_error(err: ApiError) -> ErrorData {
    match err {
        err @ (ApiError::Unauthorized | ApiError::Forbidden(_)) => auth_error(err.to_string()),
        other => upstream_error(other.to_string()),
    }
}

#[tool_handler]
impl ServerHandler for FluxValeMcp {
    fn get_info(&self) -> ServerConfig {
        let mut info = InitializeResult::new(ServerCapabilities::builder().enable_tools().build());
        info.server_info = rmcp::model::Implementation::new("FluxVale", env!("CARGO_PKG_VERSION"));
        info.instructions = Some(INSTRUCTIONS.to_string());
        info
    }

    /// The initialize gate: GET /me with the request's bearer. 401/403
    /// refuse the protocol handshake — the client must reconfigure its
    /// token. Anything else surfaces verbatim. (The handshake revs'
    /// entry point; the 2026-07-28 flow's is [`Self::discover`].)
    async fn initialize(
        &self,
        request: InitializeRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<InitializeResult, ErrorData> {
        let token = self.token(&context)?;
        upstream::check_me(self.api_base_url.clone(), token)
            .await
            .map_err(gate_error)?;
        context.peer.set_peer_info(request.clone());
        self.negotiate_initialize(&request)
    }

    /// The discovery gate — the 2026-07-28 rev's handshake
    /// replacement. Same rule as [`Self::initialize`]: the bearer must
    /// prove itself against /me before this server answers anything.
    async fn discover(
        &self,
        context: RequestContext<RoleServer>,
    ) -> Result<DiscoverResult, ErrorData> {
        let token = self.token(&context)?;
        upstream::check_me(self.api_base_url.clone(), token)
            .await
            .map_err(gate_error)?;
        Ok(DiscoverResult::from_server_info(
            self.supported_protocol_versions().into_owned(),
            self.get_info(),
        ))
    }

    /// The scope filter (the settled decision): /me fresh on EVERY
    /// tools/list — no caching; the stateless posture makes every
    /// request independent anyway. The platform's own 403s are the
    /// real enforcement; this list is what the token may call.
    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        let token = self.token(&context)?;
        let (catalog_read, instances_read) =
            upstream::scope_coverage(self.api_base_url.clone(), token)
                .await
                .map_err(|err| match err {
                    upstream::ScopeError::Auth(message) => auth_error(message),
                    upstream::ScopeError::Upstream(message) => upstream_error(message),
                })?;
        let tools: Vec<Tool> = self
            .tool_router
            .list_all()
            .into_iter()
            .filter(|tool| {
                scopes::tool_visible(&tool.name, &scopes::coverage(catalog_read, instances_read))
            })
            .collect();
        Ok(ListToolsResult::with_all_items(tools))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testapi::{self, CannedApi};
    use axum::{Router, body::Body, http::Method, http::Request, http::StatusCode};
    use serde_json::{Value, json};
    use tower::ServiceExt;

    /// A bare `http::request::Parts` (no transport needed).
    fn bare_parts() -> axum::http::request::Parts {
        axum::http::Request::builder()
            .body(())
            .unwrap()
            .into_parts()
            .0
    }

    #[test]
    fn the_token_arms_refuse_without_the_transport_guarantees() {
        // No HTTP context at all — the middleware never ran.
        let err = token_from_parts(None, None).unwrap_err();
        assert_eq!(err.code, ErrorCode::INTERNAL_ERROR);
        assert!(err.message.contains("no HTTP context"), "err: {err}");

        // A request context, but no credential in it — the shape that
        // would mean the middleware was bypassed.
        let parts = bare_parts();
        let err = token_from_parts(Some(&parts), None).unwrap_err();
        assert_eq!(err.code, ErrorCode::INVALID_REQUEST);
        assert!(err.message.contains("no bearer token"), "err: {err}");

        // The served shape: both present.
        let token = token_from_parts(Some(&parts), Some(&Token::new("fvpat_t"))).unwrap();
        assert_eq!(token.expose(), "fvpat_t");
    }

    const PAT_FULL: &str = "fvpat_full_scope";
    const PAT_CATALOG: &str = "fvpat_catalog_only";
    const PAT_DEAD: &str = "fvpat_revoked";

    // ---- drivers: a JSON-RPC POST through the real router

    fn app(server: &CannedApi) -> Router {
        crate::build_router(&server.base_url)
    }

    async fn mcp(app: &Router, body: Value, bearer: Option<&str>) -> (StatusCode, Value) {
        let method = body["method"].as_str().unwrap_or_default().to_string();
        // The header must agree with the body's own per-request version
        // when one rides _meta (rmcp's mismatch check).
        let version = body["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"]
            .as_str()
            .unwrap_or("2025-11-25")
            .to_string();
        let mut builder = Request::builder()
            .method(Method::POST)
            .uri("/mcp")
            // rmcp's DNS-rebinding guard validates the Host header
            // (loopback allowlist default) — real clients always send
            // one; the router oneshot doesn't, so name it here.
            .header("host", "localhost:4600")
            .header("content-type", "application/json")
            .header("accept", "application/json, text/event-stream")
            // The standard header naming the method (SEP-2243); the
            // per-request protocol version header names a handshake
            // rev, so no per-request _meta is demanded of these.
            .header("mcp-protocol-version", version)
            .header("mcp-method", method);
        if let Some(bearer) = bearer {
            builder = builder.header("authorization", format!("Bearer {bearer}"));
        }
        let request = builder.body(Body::from(body.to_string())).unwrap();
        let response = app.clone().oneshot(request).await.unwrap();
        let status = response.status();
        let bytes = http_body_util::BodyExt::collect(response.into_body())
            .await
            .unwrap()
            .to_bytes();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    async fn initialize(app: &Router, bearer: &str) -> (StatusCode, Value) {
        initialize_at(app, bearer, "2025-11-25").await
    }

    async fn initialize_at(app: &Router, bearer: &str, version: &str) -> (StatusCode, Value) {
        // A handshake-rev client: the version rides the BODY (no
        // per-request protocol header — that's the 2026-07-28 shape).
        let mut builder = Request::builder()
            .method(Method::POST)
            .uri("/mcp")
            .header("host", "localhost:4600")
            .header("content-type", "application/json")
            .header("accept", "application/json, text/event-stream")
            .header("mcp-method", "initialize");
        builder = builder.header("authorization", format!("Bearer {bearer}"));
        let request = builder
            .body(Body::from(
                json!({
                    "jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": {
                        "protocolVersion": version,
                        "capabilities": {},
                        "clientInfo": {"name": "w2a-test", "version": "0.0.0"}
                    }
                })
                .to_string(),
            ))
            .unwrap();
        let response = app.clone().oneshot(request).await.unwrap();
        let status = response.status();
        let bytes = http_body_util::BodyExt::collect(response.into_body())
            .await
            .unwrap()
            .to_bytes();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    /// The 2026-07-28 flow's discovery POST: server/discover with the
    /// standard header naming its method (SEP-2243 validation).
    async fn discover(app: &Router, bearer: Option<&str>) -> (StatusCode, Value) {
        let mut builder = Request::builder()
            .method(Method::POST)
            .uri("/mcp")
            .header("host", "localhost:4600")
            .header("content-type", "application/json")
            .header("accept", "application/json, text/event-stream")
            .header("mcp-protocol-version", "2026-07-28")
            .header("mcp-method", "server/discover");
        if let Some(bearer) = bearer {
            builder = builder.header("authorization", format!("Bearer {bearer}"));
        }
        let request = builder
            .body(Body::from(
                json!({"jsonrpc": "2.0", "id": 1, "method": "server/discover",
                "params": {"_meta": {
                    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                    "io.modelcontextprotocol/clientCapabilities": {}
                }}})
                .to_string(),
            ))
            .unwrap();
        let response = app.clone().oneshot(request).await.unwrap();
        let status = response.status();
        let bytes = http_body_util::BodyExt::collect(response.into_body())
            .await
            .unwrap()
            .to_bytes();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    async fn tools_list(app: &Router, bearer: &str) -> (StatusCode, Value) {
        mcp(
            app,
            json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}),
            Some(bearer),
        )
        .await
    }

    async fn tools_call(
        app: &Router,
        bearer: &str,
        name: &str,
        arguments: Value,
    ) -> (StatusCode, Value) {
        mcp(
            app,
            json!({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                   "params": {"name": name, "arguments": arguments}}),
            Some(bearer),
        )
        .await
    }

    fn result(body: &Value) -> &Value {
        body.get("result").expect("a JSON-RPC result")
    }

    fn rpc_error(body: &Value) -> (&Value, &Value) {
        let error = body.get("error").expect("a JSON-RPC error");
        (&error["code"], &error["message"])
    }

    fn tool_names(body: &Value) -> Vec<&str> {
        result(body)["tools"]
            .as_array()
            .expect("tools array")
            .iter()
            .map(|tool| tool["name"].as_str().expect("tool name"))
            .collect()
    }

    // ---- fixture: the upstream's answer per token

    fn full_scope_upstream() -> CannedApi {
        testapi::serve(&[
            ("/api/v1/me", 200, me_doc()),
            ("/api/v1/organizations", 200, orgs_doc()),
            ("/api/v1/apps", 200, apps_doc()),
            ("/api/v1/apps/wordpress", 200, app_doc()),
            ("/api/v1/instances", 200, instances_doc()),
            ("/api/v1/instances/i1", 200, instance_doc()),
        ])
    }

    fn me_doc() -> String {
        json!({
            "data": {"type": "user", "id": "01H",
                     "attributes": {"email": "me@example.com",
                                    "platform_role": "user", "username": "me"}}
        })
        .to_string()
    }

    fn orgs_doc() -> String {
        json!({"data": [
            {"type": "organization", "id": "01JORG1",
             "attributes": {"slug": "personal", "name": "Personal"}}
        ]})
        .to_string()
    }

    fn apps_doc() -> String {
        json!({"data": [
            {"type": "app", "id": "1", "attributes": {"name": "WordPress", "slug": "wordpress"}},
            {"type": "app", "id": "2", "attributes": {"name": "Kavita", "slug": "kavita"}}
        ]})
        .to_string()
    }

    fn app_doc() -> String {
        json!({"data": {"type": "app", "id": "1",
                        "attributes": {"name": "WordPress", "slug": "wordpress",
                                       "tagline": "Blogging", "file_access": true}}})
        .to_string()
    }

    fn instances_doc() -> String {
        json!({"data": [
            {"type": "instance", "id": "i1",
             "attributes": {"name": "web", "slug": "web-a1b2", "status": "running",
                            "always_on": true, "deployed_at": "2026-11-04T21:00:00Z"}}
        ]})
        .to_string()
    }

    fn instance_doc() -> String {
        json!({"data": {"type": "instance", "id": "i1",
                        "attributes": {"name": "web", "slug": "web-a1b2",
                                       "status": "running", "cpu_cores": "0.5"}}})
        .to_string()
    }

    // ---- initialize

    #[tokio::test]
    async fn initialize_with_a_live_token_negotiates_the_newest_handshake_rev() {
        let server = full_scope_upstream();
        let (status, body) = initialize(&app(&server), PAT_FULL).await;
        assert_eq!(status, StatusCode::OK);
        let result = result(&body);
        // The newest rev that still has an initialize handshake (the
        // 2026-07-28 rev replaced the handshake with server/discover).
        assert_eq!(result["protocolVersion"], "2025-11-25");
        assert_eq!(result["serverInfo"]["name"], "FluxVale");
        assert_eq!(result["serverInfo"]["version"], env!("CARGO_PKG_VERSION"));
        assert!(result["capabilities"]["tools"].is_object());
        // The gate rode upstream with the request's bearer.
        assert!(
            server
                .head(0)
                .to_lowercase()
                .contains(&format!("authorization: bearer {PAT_FULL}"))
        );
    }

    #[tokio::test]
    async fn the_stateless_discovery_flow_answers_the_gate_too() {
        // The 2026-07-28 rev: server/discover instead of initialize.
        let server = full_scope_upstream();
        let (_, body) = discover(&app(&server), Some(PAT_FULL)).await;
        let result = result(&body);
        // Server info rides the discovery's _meta; the supported
        // versions span the handshake revs and the stateless one.
        assert_eq!(
            result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"],
            "FluxVale"
        );
        assert!(
            result["supportedVersions"]
                .as_array()
                .expect("versions")
                .len()
                > 1
        );

        // And a dead token refuses discovery at the same gate.
        let dead = testapi::serve(&[("/api/v1/me", 401, unauthorized_doc())]);
        let (_, body) = discover(&app(&dead), Some(PAT_DEAD)).await;
        let (code, message) = rpc_error(&body);
        assert_eq!(code, -32600);
        assert!(
            message.as_str().unwrap().contains("revoke"),
            "message: {message}"
        );
    }

    #[tokio::test]
    async fn initialize_with_a_revoked_token_is_a_protocol_auth_error() {
        let server = testapi::serve(&[("/api/v1/me", 401, unauthorized_doc())]);
        let (status, body) = initialize(&app(&server), PAT_DEAD).await;
        assert_eq!(status, StatusCode::OK); // protocol-level: HTTP 200, JSON-RPC error
        let (code, message) = rpc_error(&body);
        assert_eq!(code, -32600);
        assert!(
            message
                .as_str()
                .unwrap()
                .contains("not signed in or token revoked"),
            "message: {message}"
        );
    }

    #[tokio::test]
    async fn initialize_with_a_forbidden_account_is_a_protocol_auth_error() {
        let server =
            testapi::serve(&[("/api/v1/me", 403, forbidden_doc("this account is refused"))]);
        let (_, body) = initialize(&app(&server), PAT_FULL).await;
        let (code, message) = rpc_error(&body);
        assert_eq!(code, -32600);
        assert!(
            message
                .as_str()
                .unwrap()
                .contains("this account is refused"),
            "message: {message}"
        );
    }

    #[tokio::test]
    async fn initialize_against_a_dead_platform_is_a_verbatim_protocol_error() {
        // Not auth — the platform is unreachable. The gate says so,
        // with the transport line inside.
        let app = crate::build_router("http://127.0.0.1:1");
        let (_, body) = initialize(&app, PAT_FULL).await;
        let (code, message) = rpc_error(&body);
        assert_eq!(code, -32603);
        assert!(
            message
                .as_str()
                .unwrap()
                .contains("the FluxVale API is unavailable"),
            "message: {message}"
        );
    }

    fn unauthorized_doc() -> String {
        json!({"errors": [{"status": "401", "title": "Unauthorized"}]}).to_string()
    }

    fn forbidden_doc(detail: &str) -> String {
        json!({"errors": [{"status": "403", "title": "Forbidden", "detail": detail}]}).to_string()
    }

    #[tokio::test]
    async fn a_request_without_a_bearer_is_an_http_challenge() {
        let server = full_scope_upstream();
        let (status, body) = mcp(
            &app(&server),
            json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(body, Value::Null); // plain-text challenge, not JSON-RPC
    }

    // ---- tools/list: the scope filter

    #[tokio::test]
    async fn the_2026_rev_lists_tools_with_per_request_metadata() {
        // The 2026-07-28 shape: protocol version + client capabilities
        // ride EVERY request's _meta (the handshake is gone).
        let server = full_scope_upstream();
        let (_, body) = mcp(
            &app(&server),
            json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list",
            "params": {"_meta": {
                "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                "io.modelcontextprotocol/clientCapabilities": {}
            }}}),
            Some(PAT_FULL),
        )
        .await;
        assert_eq!(
            tool_names(&body),
            [
                "apps_list",
                "apps_show",
                "instances_list",
                "instances_status",
                "whoami"
            ]
        );
    }

    #[tokio::test]
    async fn a_full_scope_token_sees_all_five_tools() {
        let server = full_scope_upstream();
        let (_, body) = tools_list(&app(&server), PAT_FULL).await;
        assert_eq!(
            tool_names(&body),
            [
                "apps_list",
                "apps_show",
                "instances_list",
                "instances_status",
                "whoami"
            ]
        );
    }

    #[tokio::test]
    async fn a_catalog_only_token_sees_whoami_and_the_apps_pair() {
        // /apps answers; /instances refuses with the scope detail.
        let server = testapi::serve(&[
            ("/api/v1/me", 200, me_doc()),
            ("/api/v1/apps", 200, apps_doc()),
            (
                "/api/v1/instances",
                403,
                forbidden_doc("token lacks the instances:read scope"),
            ),
        ]);
        let (_, body) = tools_list(&app(&server), PAT_CATALOG).await;
        assert_eq!(tool_names(&body), ["apps_list", "apps_show", "whoami"]);
    }

    #[tokio::test]
    async fn write_implies_read_through_the_platform_probes() {
        // An instances:write token passes the instances:read probe at
        // the platform (Scopes.grants?) — the filter honors the same
        // rule without ever seeing the scope list. Catalog is refused.
        let server = testapi::serve(&[
            ("/api/v1/me", 200, me_doc()),
            (
                "/api/v1/apps",
                403,
                forbidden_doc("token lacks the catalog:read scope"),
            ),
            ("/api/v1/instances", 200, instances_doc()),
        ]);
        let (_, body) = tools_list(&app(&server), "fvpat_instances_write").await;
        assert_eq!(
            tool_names(&body),
            ["instances_list", "instances_status", "whoami"]
        );
    }

    #[tokio::test]
    async fn a_token_with_no_matching_scopes_still_gets_the_protocol() {
        let server = testapi::serve(&[
            ("/api/v1/me", 200, me_doc()),
            (
                "/api/v1/apps",
                403,
                forbidden_doc("token lacks the catalog:read scope"),
            ),
            (
                "/api/v1/instances",
                403,
                forbidden_doc("token lacks the instances:read scope"),
            ),
        ]);
        let (_, body) = tools_list(&app(&server), "fvpat_no_domains").await;
        assert_eq!(tool_names(&body), ["whoami"]);
    }

    #[tokio::test]
    async fn tools_list_with_a_dead_token_is_a_protocol_auth_error() {
        let server = testapi::serve(&[("/api/v1/me", 401, unauthorized_doc())]);
        let (_, body) = tools_list(&app(&server), PAT_DEAD).await;
        let (code, message) = rpc_error(&body);
        assert_eq!(code, -32600);
        assert!(
            message.as_str().unwrap().contains("revoke"),
            "message: {message}"
        );
    }

    #[tokio::test]
    async fn tools_list_refuses_verbatim_on_a_transient_upstream_failure() {
        let server = testapi::serve(&[
            ("/api/v1/me", 200, me_doc()),
            ("/api/v1/apps", 429, r#"{"errors": []}"#.to_string()),
        ]);
        let (_, body) = tools_list(&app(&server), PAT_FULL).await;
        let (_, message) = rpc_error(&body);
        assert!(
            message.as_str().unwrap().contains("rate limited"),
            "message: {message}"
        );
    }

    // ---- the five tools' happy paths (structured, flat JSON)

    #[tokio::test]
    async fn whoami_returns_the_flat_identity_row() {
        let server = full_scope_upstream();
        let (_, body) = tools_call(&app(&server), PAT_FULL, "whoami", json!({})).await;
        let structured = &result(&body)["structuredContent"];
        assert_eq!(structured["id"], "01H");
        assert_eq!(structured["email"], "me@example.com");
        assert_eq!(structured["username"], "me");
        assert_eq!(structured["organizations"][0]["id"], "01JORG1");
        assert_eq!(structured["organizations"][0]["slug"], "personal");
        assert_eq!(result(&body)["isError"], false);
    }

    #[tokio::test]
    async fn apps_list_returns_the_catalog_array() {
        let server = full_scope_upstream();
        let (_, body) = tools_call(&app(&server), PAT_FULL, "apps_list", json!({})).await;
        let structured = &result(&body)["structuredContent"];
        assert_eq!(structured[0]["slug"], "wordpress");
        assert_eq!(structured[0]["id"], "1");
        assert_eq!(structured[1]["slug"], "kavita");
    }

    #[tokio::test]
    async fn apps_show_returns_one_app_by_slug() {
        let server = full_scope_upstream();
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "apps_show",
            json!({"slug": "wordpress"}),
        )
        .await;
        let structured = &result(&body)["structuredContent"];
        assert_eq!(structured["id"], "1");
        assert_eq!(structured["slug"], "wordpress");
        assert_eq!(structured["tagline"], "Blogging");
    }

    #[tokio::test]
    async fn an_unsafe_slug_is_a_tool_error_without_reaching_upstream() {
        let server = full_scope_upstream();
        let before = server.head_count();
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "apps_show",
            json!({"slug": "../etc/passwd"}),
        )
        .await;
        assert_eq!(result(&body)["isError"], true);
        let text = result(&body)["content"][0]["text"].as_str().unwrap();
        assert_eq!(text, "invalid app slug: ../etc/passwd");
        // The fence refused before any upstream call.
        assert_eq!(server.head_count(), before);
    }

    #[tokio::test]
    async fn instances_list_returns_the_rows() {
        let server = full_scope_upstream();
        let (_, body) = tools_call(&app(&server), PAT_FULL, "instances_list", json!({})).await;
        let structured = &result(&body)["structuredContent"];
        assert_eq!(structured[0]["id"], "i1");
        assert_eq!(structured[0]["slug"], "web-a1b2");
        assert_eq!(structured[0]["status"], "running");
    }

    #[tokio::test]
    async fn instances_status_takes_the_detail_and_verbose_arms() {
        let server = full_scope_upstream();
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "instances_status",
            json!({"id": "i1"}),
        )
        .await;
        let structured = &result(&body)["structuredContent"];
        assert_eq!(structured["id"], "i1");
        assert_eq!(structured["cpu_cores"], "0.5");

        let (_, body) = tools_call(&app(&server), PAT_FULL, "instances_status", json!({})).await;
        let structured = &result(&body)["structuredContent"];
        assert_eq!(structured[0]["id"], "i1");
    }

    #[tokio::test]
    async fn a_foreign_instance_is_the_friendly_404_line() {
        let server = testapi::serve(&[
            ("/api/v1/me", 200, me_doc()),
            (
                "/api/v1/instances/ghost",
                404,
                "{\"errors\": []}".to_string(),
            ),
        ]);
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "instances_status",
            json!({"id": "ghost"}),
        )
        .await;
        assert_eq!(result(&body)["isError"], true);
        let text = result(&body)["content"][0]["text"].as_str().unwrap();
        assert_eq!(text, "no such instance (or it's not yours)");
    }

    // ---- error surfacing

    #[tokio::test]
    async fn an_api_refusal_passes_through_verbatim_as_a_tool_error() {
        // A filtered-out tool called directly: the platform's 403 IS
        // the enforcement, surfaced word-for-word.
        let server = testapi::serve(&[(
            "/api/v1/apps",
            403,
            forbidden_doc("token lacks the catalog:read scope"),
        )]);
        let (_, body) = tools_call(&app(&server), PAT_CATALOG, "apps_list", json!({})).await;
        assert_eq!(result(&body)["isError"], true);
        let text = result(&body)["content"][0]["text"].as_str().unwrap();
        assert_eq!(text, "403 Forbidden: token lacks the catalog:read scope");
    }

    #[tokio::test]
    async fn a_transient_upstream_failure_is_a_verbatim_tool_error_too() {
        let server = testapi::serve(&[("/api/v1/apps", 500, r#"<html>boom</html>"#.to_string())]);
        let (_, body) = tools_call(&app(&server), PAT_FULL, "apps_list", json!({})).await;
        assert_eq!(result(&body)["isError"], true);
        let text = result(&body)["content"][0]["text"].as_str().unwrap();
        assert_eq!(text, "HTTP 500");
    }
}
