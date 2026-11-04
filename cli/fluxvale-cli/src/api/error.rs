//! The client's own error type: JSON:API error documents mapped to
//! friendly one-line messages (the contract's 401/403/429 shapes
//! included). `thiserror` here; `anyhow` at the command layer.

/// An error from [`crate::api::ApiClient`].
#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    /// 401 — the token is missing, revoked, or stale.
    #[error("not signed in or token revoked (fluxvale auth login)")]
    Unauthorized,

    /// 403 — the server names the missing scope; pass it verbatim.
    #[error("{0}")]
    Forbidden(String),

    /// 429 — `Retry-After` in seconds when the server sent one.
    #[error("rate limited, retry in {0}s")]
    RateLimited(u64),

    /// 429 without a parseable Retry-After.
    #[error("rate limited")]
    RateLimitedUnknown,

    /// Any other JSON:API error document, rendered one-line.
    #[error("{0}")]
    Api(String),

    /// Transport-level failure (DNS, connect, TLS, timeout).
    #[error("connection failed: {0}")]
    Transport(String),
}

/// The JSON:API error document body.
#[derive(Debug, serde::Deserialize)]
pub(crate) struct ErrorDocument {
    #[serde(default)]
    pub errors: Vec<ErrorObject>,
}

impl ErrorDocument {
    pub fn first_message(&self) -> Option<String> {
        self.errors.first().map(ErrorObject::message)
    }
}

/// One JSON:API error object (`{"status","title","detail"}`).
#[derive(Debug, serde::Deserialize)]
pub(crate) struct ErrorObject {
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub detail: Option<String>,
}

impl ErrorObject {
    /// The one-line form: `{status} {title}: {detail}`.
    pub fn message(&self) -> String {
        let status = self.status.as_deref().unwrap_or("error");
        let title = self.title.as_deref().unwrap_or("");
        let detail = self.detail.as_deref().unwrap_or("");
        format!("{status} {title}: {detail}")
    }
}

/// Map a non-2xx response to an [`ApiError`]. `retry_after` is the raw
/// Retry-After header value when present.
pub(crate) fn map_response(status: u16, retry_after: Option<&str>, body: &str) -> ApiError {
    let document: Option<ErrorDocument> = serde_json::from_str(body).ok();
    match status {
        401 => ApiError::Unauthorized,
        // The 403 detail names the missing scope — verbatim, not paraphrased.
        403 => ApiError::Forbidden(
            document
                .as_ref()
                .and_then(ErrorDocument::first_message)
                .unwrap_or_else(|| "forbidden".to_string()),
        ),
        429 => match retry_after.and_then(parse_retry_after) {
            Some(seconds) => ApiError::RateLimited(seconds),
            None => ApiError::RateLimitedUnknown,
        },
        _ => match document.as_ref().and_then(ErrorDocument::first_message) {
            Some(message) => ApiError::Api(message),
            None => ApiError::Api(format!("HTTP {status}")),
        },
    }
}

/// Retry-After is seconds or an HTTP-date; only seconds are useful to a
/// human at a terminal.
fn parse_retry_after(value: &str) -> Option<u64> {
    value.trim().parse::<u64>().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_object_renders_one_line() {
        let object: ErrorObject = serde_json::from_str(
            r#"{"status":"422","title":"Unprocessable","detail":"name is taken"}"#,
        )
        .unwrap();
        assert_eq!(object.message(), "422 Unprocessable: name is taken");
    }

    #[test]
    fn error_object_survives_missing_fields() {
        let object: ErrorObject = serde_json::from_str("{}").unwrap();
        assert_eq!(object.message(), "error : ");
    }

    #[test]
    fn unauthorized_is_friendly() {
        let err = map_response(401, None, r#"{"errors":[{"status":"401"}]}"#);
        assert_eq!(
            err.to_string(),
            "not signed in or token revoked (fluxvale auth login)"
        );
    }

    #[test]
    fn forbidden_passes_scope_detail_verbatim() {
        let body = r#"{"errors":[{"status":"403","title":"Forbidden",
            "detail":"token lacks the wallet scope"}]}"#;
        let err = map_response(403, None, body);
        assert_eq!(
            err.to_string(),
            "403 Forbidden: token lacks the wallet scope"
        );
    }

    #[test]
    fn rate_limited_reads_retry_after_seconds() {
        let err = map_response(429, Some("7"), r#"{"errors":[]}"#);
        assert_eq!(err.to_string(), "rate limited, retry in 7s");
    }

    #[test]
    fn rate_limited_without_retry_after() {
        let err = map_response(429, None, "{}");
        assert_eq!(err.to_string(), "rate limited");
        // An HTTP-date Retry-After is not seconds — same fallback.
        let err = map_response(429, Some("Wed, 04 Nov 2026 00:00:00 GMT"), "{}");
        assert_eq!(err.to_string(), "rate limited");
    }

    #[test]
    fn other_statuses_render_the_document() {
        let body = r#"{"errors":[{"status":"422","title":"Unprocessable",
            "detail":"exposure cannot be public for a private instance"}]}"#;
        let err = map_response(422, None, body);
        assert_eq!(
            err.to_string(),
            "422 Unprocessable: exposure cannot be public for a private instance"
        );
    }

    #[test]
    fn non_json_api_body_falls_back_to_status() {
        let err = map_response(500, None, "<html>boom</html>");
        assert_eq!(err.to_string(), "HTTP 500");
    }
}
