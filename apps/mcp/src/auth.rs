//! Bearer extraction: the MCP client sends its PAT per request
//! (`Authorization: Bearer fvpat_…` — how remote MCP clients are
//! configured), the middleware lifts it into request extensions, and
//! every protocol request's own token then rides into its tool calls.
//! The value is never logged and never echoed — [`Token`]'s redacted
//! formatting stays the only rendering.

use axum::{
    extract::Request,
    http::{StatusCode, header},
    middleware::Next,
    response::{IntoResponse, Response},
};
use fluxvale_api::Token;

/// The per-request credential, inserted by [`require_bearer`]. Picked
/// up out of the injected `http::request::Parts` extensions by the
/// handlers (rmcp's documented pattern for reading the raw HTTP
/// request).
#[derive(Debug, Clone)]
pub(crate) struct McpAuth(pub Token);

/// Reject a request without a usable bearer: the protocol-correct 401
/// challenge (RFC 6750), the same shape the retiring platform server
/// returns — the client is told to reconfigure its token.
pub(crate) async fn require_bearer(request: Request, next: Next) -> Response {
    match bearer(&request) {
        Some(token) => {
            let mut request = request;
            request.extensions_mut().insert(McpAuth(token));
            next.run(request).await
        }
        None => challenge(),
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

fn challenge() -> Response {
    (
        StatusCode::UNAUTHORIZED,
        [(header::WWW_AUTHENTICATE, "Bearer")],
        "unauthorized",
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{Router, extract::Extension, middleware, routing::get};
    use tower::ServiceExt;

    fn app() -> Router {
        Router::new()
            .route(
                "/ok",
                get(|Extension(McpAuth(token)): Extension<McpAuth>| async move {
                    token.expose().to_string()
                }),
            )
            .layer(middleware::from_fn(require_bearer))
    }

    fn request(auth: Option<&str>) -> Request {
        let mut builder = axum::http::Request::builder().uri("/ok");
        if let Some(auth) = auth {
            builder = builder.header(header::AUTHORIZATION, auth);
        }
        builder.body(axum::body::Body::empty()).unwrap()
    }

    async fn run(auth: Option<&str>) -> Response {
        app().oneshot(request(auth)).await.unwrap()
    }

    #[tokio::test]
    async fn a_bearer_token_passes_through_to_the_route() {
        // The route's own Extension<McpAuth> extractor is the proof
        // the middleware inserted the credential.
        let response = run(Some("Bearer fvpat_testtoken")).await;
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = http_body_util::BodyExt::collect(response.into_body())
            .await
            .unwrap()
            .to_bytes();
        assert_eq!(&bytes[..], b"fvpat_testtoken");
    }

    #[test]
    fn token_redaction_survives_the_extension_debug() {
        // The credential's own discipline: no value in any rendering.
        let rendered = format!("{:?}", McpAuth(Token::new("fvpat_secretvalue")));
        assert!(
            !rendered.contains("fvpat_secretvalue"),
            "leaked: {rendered}"
        );
    }

    #[tokio::test]
    async fn a_missing_header_is_challenged() {
        let response = run(None).await;
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        let parts = response.into_parts().0;
        assert_eq!(
            parts
                .headers
                .get(header::WWW_AUTHENTICATE)
                .and_then(|v| v.to_str().ok()),
            Some("Bearer")
        );
    }

    #[tokio::test]
    async fn a_non_bearer_scheme_is_challenged() {
        for auth in ["Basic dXNlcjpwYXNz", "Bearer", "Bearer ", "bearer"] {
            let response = run(Some(auth)).await;
            assert_eq!(
                response.status(),
                StatusCode::UNAUTHORIZED,
                "scheme {auth:?} must be refused"
            );
        }
    }

    #[tokio::test]
    async fn the_scheme_is_case_insensitive() {
        let response = run(Some("bearer fvpat_testtoken")).await;
        assert_eq!(response.status(), StatusCode::OK);
    }
}
