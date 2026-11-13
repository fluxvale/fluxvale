//! Bearer extraction + resource-server validation (#766): the MCP
//! client sends its OAuth access token (or a PAT) per request, the
//! middleware proves it against the platform's `/me` before rmcp sees
//! the request, and every protocol request's own token then rides into
//! its tool calls. The value is never logged and never echoed —
//! [`Token`]'s redacted formatting stays the only rendering.
//!
//! The platform is the authorization server; this server holds no
//! tokens, no session state, and no secrets. `/me` is one upstream read
//! per MCP request: it is the RS's token validation, and its
//! `meta.scopes` is also what `tools/list` filters on, so the old
//! per-handler gate and scope read collapse into one call.

use std::sync::Arc;

use axum::{
    extract::{Request, State},
    http::{StatusCode, header},
    middleware::Next,
    response::{IntoResponse, Response},
};
use fluxvale_api::Token;

use crate::upstream::{self, ScopeError};

/// The scopes the MCP surface understands — advertised in the RFC 9728
/// metadata and the 401 challenge. `offline_access` is deliberately not
/// here: refresh is the authorization server's concern, not a resource
/// requirement.
pub(crate) const SCOPES_SUPPORTED: &[&str] = &[
    "catalog:read",
    "instances:read",
    "instances:write",
    "backups:read",
    "backups:write",
    "gateways:read",
    "gateways:write",
    "wallet:read",
];

/// The per-request credential + the scope list `/me` reported, inserted
/// by [`require_bearer`]. Picked up out of the injected
/// `http::request::Parts` extensions by the handlers (rmcp's documented
/// pattern for reading the raw HTTP request).
#[derive(Debug, Clone)]
pub(crate) struct McpAuth {
    pub token: Token,
    /// `Some` for an OAuth access token (the middleware validated it
    /// against `/me` and cached its scopes); `None` for the legacy PAT
    /// path, whose handlers keep their existing `/me` gates.
    pub scopes: Option<Vec<String>>,
}

/// The middleware's immutable deployment facts.
#[derive(Clone)]
pub(crate) struct AuthState {
    api_base_url: Arc<str>,
    resource_metadata_url: String,
    challenge_scope: String,
}

impl AuthState {
    pub(crate) fn new(api_base_url: &str, public_url: &str) -> Self {
        let origin = public_url
            .strip_suffix("/mcp")
            .unwrap_or(public_url)
            .trim_end_matches('/');

        Self {
            api_base_url: Arc::from(api_base_url),
            resource_metadata_url: format!("{origin}/.well-known/oauth-protected-resource"),
            challenge_scope: SCOPES_SUPPORTED.join(" "),
        }
    }
}

/// The protected-resource metadata handler's state.
#[derive(Clone)]
pub(crate) struct MetadataState {
    pub public_url: String,
    pub authorization_server: String,
}

impl MetadataState {
    pub(crate) fn new(public_url: &str, authorization_server: &str) -> Self {
        Self {
            public_url: public_url.to_string(),
            authorization_server: authorization_server.to_string(),
        }
    }
}

/// Reject a request without a usable bearer, then validate the bearer
/// against the platform. Missing/invalid/expired credentials get the
/// protocol-correct 401 challenge (RFC 6750 + RFC 9728); a transient
/// platform failure is a 503 the client may retry.
pub(crate) async fn require_bearer(
    State(state): State<AuthState>,
    request: Request,
    next: Next,
) -> Response {
    let Some(token) = bearer(&request) else {
        return challenge(&state, None);
    };

    // OAuth access tokens are validated here, per request; the legacy
    // PAT path keeps its existing handler gates (additive, #766).
    if !token.expose().starts_with("fvoat_") {
        let mut request = request;
        request.extensions_mut().insert(McpAuth {
            token,
            scopes: None,
        });
        return next.run(request).await;
    }

    match upstream::me_scopes(state.api_base_url.clone(), token.clone()).await {
        Ok(scopes) => {
            let mut request = request;
            request.extensions_mut().insert(McpAuth {
                token,
                scopes: Some(scopes),
            });
            next.run(request).await
        }
        Err(ScopeError::Auth(_message) | ScopeError::Shape(_message)) => {
            challenge(&state, Some("invalid_token"))
        }
        Err(ScopeError::Upstream(_message)) => (
            StatusCode::SERVICE_UNAVAILABLE,
            "the FluxVale API is unavailable",
        )
            .into_response(),
    }
}

/// The header parse: `Bearer <token>` (scheme case-insensitive per
/// RFC 7235, non-empty token). Anything else — missing header, other
/// scheme, empty value — is no credential.
fn bearer(request: &Request) -> Option<Token> {
    let value = request
        .headers()
        .get(header::AUTHORIZATION)?
        .to_str()
        .ok()?;
    let (scheme, token) = value.split_once(' ')?;
    if !scheme.eq_ignore_ascii_case("bearer") {
        return None;
    }
    let token = token.trim();
    if token.is_empty() {
        return None;
    }
    Some(Token::new(token.to_owned()))
}

fn challenge(state: &AuthState, error: Option<&str>) -> Response {
    let error = error
        .map(|value| format!(", error=\"{value}\""))
        .unwrap_or_default();

    let value = format!(
        "Bearer resource_metadata=\"{}\", scope=\"{}\"{error}",
        state.resource_metadata_url, state.challenge_scope
    );

    (
        StatusCode::UNAUTHORIZED,
        [(header::WWW_AUTHENTICATE, value)],
        "unauthorized",
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{Router, body::Body, extract::Extension, http::Request, middleware, routing::get};
    use tower::ServiceExt;

    use crate::testapi::{self, CannedApi};

    fn state() -> AuthState {
        AuthState::new("http://127.0.0.1:1", "https://mcp.fluxvale.com/mcp")
    }

    fn app(api: &CannedApi) -> Router {
        let auth = AuthState::new(&api.base_url, "https://mcp.fluxvale.com/mcp");

        Router::new()
            .route(
                "/ok",
                get(|Extension(auth): Extension<McpAuth>| async move {
                    format!("{} {:?}", auth.token.expose(), auth.scopes)
                }),
            )
            .layer(middleware::from_fn_with_state(auth, require_bearer))
    }

    fn request(auth: Option<&str>) -> Request<Body> {
        let mut builder = Request::builder().uri("/ok");
        if let Some(auth) = auth {
            builder = builder.header(header::AUTHORIZATION, auth);
        }
        builder.body(Body::empty()).unwrap()
    }

    fn me_ok() -> CannedApi {
        testapi::serve(&[(
            "/api/v1/me",
            200,
            serde_json::json!({
                "data": {"type": "user", "id": "u1", "attributes": {}},
                "meta": {"scopes": ["instances:read", "wallet:read"]}
            })
            .to_string(),
        )])
    }

    async fn run(api: &CannedApi, auth: Option<&str>) -> Response {
        app(api).oneshot(request(auth)).await.unwrap()
    }

    #[tokio::test]
    async fn a_valid_bearer_passes_through_with_its_scopes() {
        let api = me_ok();
        let response = run(&api, Some("Bearer fvpat_testtoken")).await;

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[test]
    fn token_redaction_survives_the_extension_debug() {
        let rendered = format!(
            "{:?}",
            McpAuth {
                token: Token::new("fvpat_secretvalue"),
                scopes: None
            }
        );
        assert!(
            !rendered.contains("fvpat_secretvalue"),
            "leaked: {rendered}"
        );
    }

    #[tokio::test]
    async fn a_missing_header_is_challenged_with_the_metadata_url() {
        let api = me_ok();
        let response = run(&api, None).await;
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

        let header = response
            .headers()
            .get(header::WWW_AUTHENTICATE)
            .and_then(|value| value.to_str().ok())
            .unwrap();

        assert!(header.contains(
            "resource_metadata=\"https://mcp.fluxvale.com/.well-known/oauth-protected-resource\""
        ));
        assert!(header.contains("scope=\"catalog:read instances:read"));
    }

    #[tokio::test]
    async fn a_non_bearer_scheme_is_challenged() {
        let api = me_ok();

        for auth in ["Basic dXNlcjpwYXNz", "Bearer", "Bearer ", "bearer"] {
            let response = run(&api, Some(auth)).await;
            assert_eq!(
                response.status(),
                StatusCode::UNAUTHORIZED,
                "scheme {auth:?} must be refused"
            );
        }
    }

    #[tokio::test]
    async fn the_scheme_is_case_insensitive() {
        let api = me_ok();
        let response = run(&api, Some("bearer fvpat_testtoken")).await;
        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn an_oauth_access_token_is_validated_and_carries_its_scopes() {
        let api = me_ok();
        let response = run(&api, Some("Bearer fvoat_testtoken")).await;
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(api.head_count(), 1);
    }

    #[tokio::test]
    async fn a_pat_is_not_validated_by_the_middleware() {
        let api = testapi::serve(&[]);
        let response = run(&api, Some("Bearer fvpat_testtoken")).await;
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(api.head_count(), 0);
    }

    #[tokio::test]
    async fn a_dead_oauth_token_is_an_http_challenge() {
        let api = testapi::serve(&[(
            "/api/v1/me",
            401,
            serde_json::json!({"errors": [{"status": "401", "title": "Unauthorized"}]}).to_string(),
        )]);
        let response = run(&api, Some("Bearer fvoat_dead")).await;
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

        let header = response
            .headers()
            .get(header::WWW_AUTHENTICATE)
            .and_then(|value| value.to_str().ok())
            .unwrap();
        assert!(header.contains("error=\"invalid_token\""));
    }

    #[tokio::test]
    async fn a_transient_platform_failure_is_503() {
        let api = testapi::serve(&[("/api/v1/me", 429, "{}".to_string())]);
        let response = run(&api, Some("Bearer fvoat_testtoken")).await;
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    }

    #[test]
    fn the_state_challenge_scope_is_the_supported_set() {
        let state = state();
        assert!(state.challenge_scope.contains("instances:write"));
        assert!(state.challenge_scope.contains("wallet:read"));
    }
}
