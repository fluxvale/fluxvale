//! The upstream reads: the five tools' `/api/v1` calls, mirroring the
//! CLI's reads.rs exactly (same routes, same params, the same flat
//! `id`-hoisted row shape). Errors surface VERBATIM — the crate
//! preserves the JSON:API detail and neither layer rewrites it; the
//! one local addition is the CLI's friendly 404 for a missing single
//! thing. Calls run on the blocking pool (the client crate is ureq).

use fluxvale_api::{ApiClient, ApiError, Document, Resource, Token};
use serde_json::{Value, json};
use std::sync::Arc;

/// The error shapes the tools/list scope probes answer.
#[derive(Debug)]
pub(crate) enum ScopeError {
    /// 401/403 from /me — the token is dead or the account refused;
    /// the caller reconfigures its token.
    Auth(String),
    /// Anything else (429, 5xx, transport) — transient or upstream;
    /// surfaced verbatim, no retries.
    Upstream(String),
}

// ---- the async surface: per-request client, blocking pool

/// `GET /me` — the initialize gate: 401/403 refuse the connection.
pub(crate) async fn check_me(base: Arc<str>, token: Token) -> Result<(), ApiError> {
    on_blocking(move || ApiClient::new(&base, token).get("/me").map(|_| ())).await
}

/// `whoami` — GET /me, then GET /organizations (#362 T6a): the flat
/// identity row with the org ids. An older backend without the orgs
/// route degrades to no organizations — a 404 there is "no discovery
/// surface", not an error; anything else propagates.
pub(crate) async fn whoami(base: Arc<str>, token: Token) -> Result<Value, String> {
    on_blocking_string(move || {
        let client = ApiClient::new(&base, token);
        let me = client.get("/me").map_err(message)?;
        let user = one_resource(me, "user")?;
        let organizations = match client.get("/organizations") {
            Ok(document) => document
                .resources()
                .iter()
                .map(|org| {
                    json!({
                        "id": org.id,
                        "slug": org.attributes.get("slug"),
                        "name": org.attributes.get("name"),
                    })
                })
                .collect::<Vec<_>>(),
            Err(ApiError::NotFound) => Vec::new(),
            Err(err) => return Err(message(err)),
        };
        let mut row = with_id(&user);
        if let Value::Object(map) = &mut row {
            map.insert("organizations".to_string(), Value::Array(organizations));
        }
        Ok(row)
    })
    .await
}

/// `apps_list` — GET /apps: the catalog, one flat row per app.
pub(crate) async fn apps_list(base: Arc<str>, token: Token) -> Result<Value, String> {
    on_blocking_string(move || {
        let document = ApiClient::new(&base, token).get("/apps").map_err(message)?;
        Ok(rows(&document))
    })
    .await
}

/// `apps_show` — GET /apps/{slug}: one catalog app, all its fields.
pub(crate) async fn apps_show(base: Arc<str>, token: Token, slug: String) -> Result<Value, String> {
    safe_segment("app slug", &slug)?;
    on_blocking_string(move || {
        let document = ApiClient::new(&base, token)
            .get(&format!("/apps/{slug}"))
            .map_err(|err| friendly_404(err, "app"))?;
        one_resource(document, "app").map(|resource| with_id(&resource))
    })
    .await
}

/// `instances_list` — GET /instances: one flat row per instance.
pub(crate) async fn instances_list(base: Arc<str>, token: Token) -> Result<Value, String> {
    on_blocking_string(move || {
        let document = ApiClient::new(&base, token)
            .get("/instances")
            .map_err(message)?;
        Ok(rows(&document))
    })
    .await
}

/// `instances_status` — GET /instances/{id} for one instance's detail;
/// with no id, the same collection as the verbose list (the CLI's
/// two arms).
pub(crate) async fn instances_status(
    base: Arc<str>,
    token: Token,
    id: Option<String>,
) -> Result<Value, String> {
    let id = match id {
        Some(id) => {
            safe_segment("instance id", &id)?;
            Some(id)
        }
        None => None,
    };
    on_blocking_string(move || match id {
        Some(id) => {
            let document = ApiClient::new(&base, token)
                .get(&format!("/instances/{id}"))
                .map_err(|err| friendly_404(err, "instance"))?;
            one_resource(document, "instance").map(|resource| with_id(&resource))
        }
        None => {
            let document = ApiClient::new(&base, token)
                .get("/instances")
                .map_err(message)?;
            Ok(rows(&document))
        }
    })
    .await
}

/// The tools/list coverage probes: `/me` fresh (the settled decision —
/// no caching), then the two read domains the catalog tools need. A
/// domain 403s when the token lacks its read scope; the platform's own
/// boundary is the oracle, and its write-implies-read rule rides with
/// it (a write-scoped token passes the read probe).
pub(crate) async fn scope_coverage(
    base: Arc<str>,
    token: Token,
) -> Result<(bool, bool), ScopeError> {
    on_blocking(move || {
        let client = ApiClient::new(&base, token);
        client.get("/me").map_err(|err| match err {
            // A dead token or a refused account — never a tool answer.
            err @ (ApiError::Unauthorized | ApiError::Forbidden(_)) => {
                ScopeError::Auth(err.to_string())
            }
            other => ScopeError::Upstream(other.to_string()),
        })?;
        let read = |path: &str| match client.get(path) {
            Ok(_) => Ok(true),
            Err(ApiError::Forbidden(_)) => Ok(false),
            Err(err) => Err(ScopeError::Upstream(err.to_string())),
        };
        let catalog = read("/apps")?;
        let instances = read("/instances")?;
        Ok((catalog, instances))
    })
    .await
}

// ---- the blocking helpers

async fn on_blocking<T: Send + 'static>(call: impl FnOnce() -> T + Send + 'static) -> T {
    tokio::task::spawn_blocking(call)
        .await
        .expect("the blocking task must not panic")
}

async fn on_blocking_string<T: Send + 'static>(
    call: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    on_blocking(call).await
}

/// ApiError → the caller-facing message, VERBATIM (the crate's own
/// one-line rendering of the JSON:API document — detail included).
fn message(err: ApiError) -> String {
    err.to_string()
}

/// 404 → "no such <thing> (or it's not yours)" — the API can't tell a
/// missing row from a foreign one, and neither should we (the CLI's
/// friendly_404).
fn friendly_404(err: ApiError, thing: &str) -> String {
    match err {
        ApiError::NotFound => format!("no such {thing} (or it's not yours)"),
        other => message(other),
    }
}

/// One URL path segment: interpolated into request paths, so `/ ? # %`
/// (and dot segments) are refused up front — they'd address a different
/// route (the CLI's safe_segment).
fn safe_segment(thing: &str, value: &str) -> Result<(), String> {
    let bad = value.is_empty()
        || value.contains(['/', '?', '#', '%'])
        || value.contains("..")
        || value.chars().any(char::is_whitespace);
    if bad {
        return Err(format!("invalid {thing}: {value}"));
    }
    Ok(())
}

/// The JSON:API resource-level `id` hoisted into the attrs map, so the
/// flat row carries it (`jq .id`) and the agent can feed its own
/// follow-up calls (the CLI's with_id).
fn with_id(resource: &Resource) -> Value {
    match &resource.attributes {
        Value::Object(map) => {
            let mut map = map.clone();
            map.insert("id".to_string(), json!(resource.id));
            Value::Object(map)
        }
        other => other.clone(),
    }
}

/// One resource or a loud message — a silently-empty document must not
/// render as an empty object (the CLI's one_resource).
fn one_resource(document: Document, type_name: &str) -> Result<Resource, String> {
    let mut resources = document.resources();
    match resources.len() {
        1 => Ok(resources.remove(0)),
        0 => Err(format!("the API returned no {type_name}")),
        _ => Err(format!(
            "the API returned {} {type_name} resources, expected one",
            resources.len()
        )),
    }
}

/// Every resource of a collection as flat rows.
fn rows(document: &Document) -> Value {
    Value::Array(document.resources().iter().map(with_id).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    // ---- the canned upstream: the shared pattern (crate::testapi)

    use crate::testapi::{self, CannedApi};

    fn base(server: &CannedApi) -> Arc<str> {
        Arc::from(server.base_url.as_str())
    }

    fn serve(routes: &[(&str, u16, &str)]) -> CannedApi {
        let routes = routes
            .iter()
            .map(|(path, status, body)| (*path, *status, (*body).to_string()))
            .collect::<Vec<_>>();
        testapi::serve(&routes)
    }

    fn envelope(value: Value) -> String {
        value.to_string()
    }

    fn token() -> Token {
        Token::new("fvpat_testtoken")
    }

    fn me_doc() -> Value {
        json!({
            "data": {"type": "user", "id": "01H",
                     "attributes": {"email": "me@example.com",
                                    "platform_role": "user", "username": "me"}}
        })
    }

    fn orgs_doc() -> Value {
        json!({"data": [
            {"type": "organization", "id": "01JORG1",
             "attributes": {"slug": "personal", "name": "Personal"}}
        ]})
    }

    #[tokio::test]
    async fn whoami_rides_me_then_the_orgs_into_one_flat_row() {
        let server = serve(&[
            ("/api/v1/me", 200, &envelope(me_doc())),
            ("/api/v1/organizations", 200, &envelope(orgs_doc())),
        ]);
        let row = whoami(base(&server), token()).await.unwrap();
        assert_eq!(row["id"], "01H");
        assert_eq!(row["email"], "me@example.com");
        assert_eq!(row["platform_role"], "user");
        assert_eq!(row["organizations"][0]["id"], "01JORG1");
        assert_eq!(row["organizations"][0]["slug"], "personal");
        assert_eq!(row["organizations"][0]["name"], "Personal");
        // Both reads carried the bearer.
        let me = server.head(0).to_lowercase();
        assert!(
            me.contains("authorization: bearer fvpat_testtoken"),
            "head: {me}"
        );
        let orgs = server.head(1).to_lowercase();
        assert!(
            orgs.starts_with("get /api/v1/organizations"),
            "head: {orgs}"
        );
    }

    #[tokio::test]
    async fn whoami_degrades_a_missing_orgs_route_to_no_organizations() {
        let server = serve(&[
            ("/api/v1/me", 200, &envelope(me_doc())),
            // A 404 on /organizations alone is "no discovery surface".
        ]);
        let row = whoami(base(&server), token()).await.unwrap();
        assert_eq!(row["organizations"], json!([]));
    }

    #[tokio::test]
    async fn whoami_passes_other_org_errors_through() {
        let server = serve(&[
            ("/api/v1/me", 200, &envelope(me_doc())),
            (
                "/api/v1/organizations",
                429,
                &envelope(json!({"errors": []})),
            ),
        ]);
        let err = whoami(base(&server), token()).await.unwrap_err();
        assert_eq!(err, "rate limited"); // verbatim, no scrubbing
    }

    #[tokio::test]
    async fn apps_list_renders_flat_rows_with_the_id_hoisted() {
        let body = &envelope(json!({"data": [
            {"type": "app", "id": "1", "attributes": {"name": "WordPress", "slug": "wordpress"}}
        ]}));
        let server = serve(&[("/api/v1/apps", 200, body)]);
        let rows = apps_list(base(&server), token()).await.unwrap();
        assert_eq!(rows[0]["slug"], "wordpress");
        assert_eq!(rows[0]["id"], "1");
    }

    #[tokio::test]
    async fn apps_show_addresses_the_slug_route_and_unwraps_one_resource() {
        let body = &envelope(json!({"data": {
            "type": "app", "id": "1", "attributes": {"name": "WordPress", "slug": "wordpress"}
        }}));
        let server = serve(&[("/api/v1/apps/wordpress", 200, body)]);
        let row = apps_show(base(&server), token(), "wordpress".into())
            .await
            .unwrap();
        assert_eq!(row["id"], "1");
        assert_eq!(row["name"], "WordPress");
        let head = server.head(0).to_lowercase();
        assert!(
            head.starts_with("get /api/v1/apps/wordpress"),
            "head: {head}"
        );
    }

    #[tokio::test]
    async fn unsafe_slugs_are_refused_locally_without_a_wire_call() {
        // A dead-port origin: reaching it would mean the fence failed.
        let dead: Arc<str> = Arc::from("http://127.0.0.1:1");
        for slug in ["../etc", "a/b", "a%20b", "a?b", "a#b", "a b", ""] {
            let err = apps_show(dead.clone(), token(), slug.into())
                .await
                .unwrap_err();
            assert_eq!(err, format!("invalid app slug: {slug}"));
        }
    }

    #[tokio::test]
    async fn apps_show_404_is_the_friendly_line() {
        let server = serve(&[("/api/v1/apps/wordpress", 404, "{\"errors\":[]}")]);
        let err = apps_show(base(&server), token(), "wordpress".into())
            .await
            .unwrap_err();
        assert_eq!(err, "no such app (or it's not yours)");
    }

    #[tokio::test]
    async fn a_transient_failure_on_a_show_passes_friendly_404_through() {
        // friendly_404's other arm: only the 404 is rewritten; every
        // other ApiError keeps its own words.
        let server = serve(&[("/api/v1/apps/wordpress", 429, r#"{"errors": []}"#)]);
        let err = apps_show(base(&server), token(), "wordpress".into())
            .await
            .unwrap_err();
        assert_eq!(err, "rate limited");
    }

    #[tokio::test]
    async fn instances_status_takes_both_arms() {
        let list_body = &envelope(json!({"data": [
            {"type": "instance", "id": "i1", "attributes": {"name": "web", "status": "running"}}
        ]}));
        let list = serve(&[("/api/v1/instances", 200, list_body)]);
        let rows = instances_list(base(&list), token()).await.unwrap();
        assert_eq!(rows[0]["id"], "i1");
        assert_eq!(rows[0]["status"], "running");

        let one_body = &envelope(json!({"data": {
            "type": "instance", "id": "i1", "attributes": {"name": "web", "status": "running"}
        }}));
        let one = serve(&[("/api/v1/instances/i1", 200, one_body)]);
        let row = instances_status(base(&one), token(), Some("i1".into()))
            .await
            .unwrap();
        assert_eq!(row["id"], "i1");
        let head = one.head(0).to_lowercase();
        assert!(head.starts_with("get /api/v1/instances/i1"), "head: {head}");
    }

    #[tokio::test]
    async fn instances_status_refuses_an_unsafe_id_locally() {
        let dead: Arc<str> = Arc::from("http://127.0.0.1:1");
        let err = instances_status(dead, token(), Some("a/b".into()))
            .await
            .unwrap_err();
        assert_eq!(err, "invalid instance id: a/b");
        // The no-id arm needs no fence — it's a collection read.
        let server = serve(&[("/api/v1/instances", 200, &envelope(json!({"data": []})))]);
        let rows = instances_status(base(&server), token(), None)
            .await
            .unwrap();
        assert_eq!(rows, json!([]));
    }

    #[tokio::test]
    async fn a_foreign_instance_is_the_friendly_404_line() {
        let server = serve(&[("/api/v1/instances/i1", 404, "{\"errors\":[]}")]);
        let err = instances_status(base(&server), token(), Some("i1".into()))
            .await
            .unwrap_err();
        assert_eq!(err, "no such instance (or it's not yours)");
    }

    #[tokio::test]
    async fn api_error_messages_pass_through_verbatim() {
        // The JSON:API detail rides unrewritten (the CLI prints the
        // same line; the MCP surface returns it).
        let body = r#"{"errors":[{"status":"403","title":"Forbidden","detail":"token lacks the catalog:read scope"}]}"#;
        let server = serve(&[("/api/v1/apps", 403, body)]);
        let err = apps_list(base(&server), token()).await.unwrap_err();
        assert_eq!(err, "403 Forbidden: token lacks the catalog:read scope");
    }

    // ---- the scope probes

    #[tokio::test]
    async fn full_coverage_reads_both_domains_true() {
        let server = serve(&[
            ("/api/v1/me", 200, &envelope(me_doc())),
            ("/api/v1/apps", 200, &envelope(json!({"data": []}))),
            ("/api/v1/instances", 200, &envelope(json!({"data": []}))),
        ]);
        let coverage = scope_coverage(base(&server), token()).await;
        assert_eq!(coverage.unwrap(), (true, true));
    }

    #[tokio::test]
    async fn a_catalog_only_token_answers_apps_yes_instances_no() {
        let refused = &envelope(json!({"errors": [
            {"status": "403", "title": "Forbidden", "detail": "token lacks the instances:read scope"}
        ]}));
        let server = serve(&[
            ("/api/v1/me", 200, &envelope(me_doc())),
            ("/api/v1/apps", 200, &envelope(json!({"data": []}))),
            ("/api/v1/instances", 403, refused),
        ]);
        let coverage = scope_coverage(base(&server), token()).await;
        assert_eq!(coverage.unwrap(), (true, false));
    }

    #[tokio::test]
    async fn a_dead_platform_on_me_is_an_upstream_error_with_the_verbatim_line() {
        let body = &envelope(json!({"errors": [
            {"status": "500", "title": "Internal Server Error"}
        ]}));
        let server = serve(&[("/api/v1/me", 500, body)]);
        let err = scope_coverage(base(&server), token()).await.unwrap_err();
        assert!(matches!(err, ScopeError::Upstream(_)));
    }

    #[tokio::test]
    async fn a_dead_token_is_an_auth_error_carrying_the_api_line() {
        let body = &envelope(json!({"errors": [
            {"status": "401", "title": "Unauthorized"}
        ]}));
        let server = serve(&[("/api/v1/me", 401, body)]);
        let err = scope_coverage(base(&server), token()).await.unwrap_err();
        assert!(matches!(err, ScopeError::Auth(_)));
        assert_eq!(
            err_message(&err),
            "not signed in or token revoked (fluxvale auth login)"
        );
    }

    #[tokio::test]
    async fn a_forbidden_account_is_an_auth_error_too() {
        let body = &envelope(json!({"errors": [
            {"status": "403", "title": "Forbidden", "detail": "denied"}
        ]}));
        let server = serve(&[("/api/v1/me", 403, body)]);
        let err = scope_coverage(base(&server), token()).await.unwrap_err();
        assert!(matches!(err, ScopeError::Auth(_)));
    }

    #[tokio::test]
    async fn transient_failures_are_upstream_errors_with_the_verbatim_line() {
        let server = serve(&[
            ("/api/v1/me", 200, &envelope(me_doc())),
            ("/api/v1/apps", 429, &envelope(json!({"errors": []}))),
        ]);
        let err = scope_coverage(base(&server), token()).await.unwrap_err();
        assert!(matches!(err, ScopeError::Upstream(_)));
        assert_eq!(err_message(&err), "rate limited");
    }

    fn err_message(err: &ScopeError) -> String {
        match err {
            ScopeError::Auth(message) | ScopeError::Upstream(message) => message.clone(),
        }
    }

    // ---- the pure helpers

    #[test]
    fn with_id_hoists_the_resource_id_into_the_map() {
        let resource = Resource {
            r#type: "app".into(),
            id: "1".into(),
            attributes: json!({"slug": "wordpress"}),
        };
        let row = with_id(&resource);
        assert_eq!(row["id"], "1");
        assert_eq!(row["slug"], "wordpress");
    }

    #[test]
    fn with_id_survives_a_non_map_body() {
        let resource = Resource {
            r#type: "app".into(),
            id: "1".into(),
            attributes: Value::Null,
        };
        assert_eq!(with_id(&resource), Value::Null);
    }

    #[test]
    fn one_resource_is_loud_on_zero_and_many() {
        let none: Document = serde_json::from_str(r#"{"data": []}"#).unwrap();
        assert_eq!(
            one_resource(none, "user").unwrap_err(),
            "the API returned no user"
        );
        let many: Document = serde_json::from_str(
            r#"{"data": [{"type": "user", "id": "1"}, {"type": "user", "id": "2"}]}"#,
        )
        .unwrap();
        assert_eq!(
            one_resource(many, "user").unwrap_err(),
            "the API returned 2 user resources, expected one"
        );
    }

    #[test]
    fn safe_segment_refuses_the_path_shaping_characters() {
        assert!(safe_segment("slug", "ok-slug").is_ok());
        for bad in ["", "a/b", "a?b", "a#b", "a%b", "..", "a b"] {
            assert!(safe_segment("slug", bad).is_err(), "{bad:?} must refuse");
        }
    }
}
