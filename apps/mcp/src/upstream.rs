//! The upstream calls: the tools' `/api/v1` verbs, mirroring the CLI's
//! reads.rs/writes.rs exactly (same routes, same params, same bodies,
//! the same flat `id`-hoisted row shape). Errors surface VERBATIM —
//! the crate preserves the JSON:API detail and neither layer rewrites
//! it; the one local addition is the CLI's friendly 404 for a missing
//! single thing. Calls run on the blocking pool (the client crate is
//! ureq).

use fluxvale_api::{ApiClient, ApiError, Document, Resource, Token};
use serde_json::{Value, json};
use std::sync::Arc;

/// The error shapes the tools/list scope source answers.
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

/// `apps_list` — GET /apps: the catalog as `{"apps": […]}`, one flat
/// row per app (the retiring server's response shape).
pub(crate) async fn apps_list(base: Arc<str>, token: Token) -> Result<Value, String> {
    on_blocking_string(move || {
        let document = ApiClient::new(&base, token).get("/apps").map_err(message)?;
        Ok(json!({ "apps": rows(&document) }))
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

/// `instances_list` — GET /instances: `{"instances": […]}`, one flat
/// row per instance (the retiring server's response shape).
pub(crate) async fn instances_list(base: Arc<str>, token: Token) -> Result<Value, String> {
    on_blocking_string(move || {
        let document = ApiClient::new(&base, token)
            .get("/instances")
            .map_err(message)?;
        Ok(json!({ "instances": rows(&document) }))
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
        // The no-id arm is the verbose list, same named-key shape as
        // `instances_list`.
        None => {
            let document = ApiClient::new(&base, token)
                .get("/instances")
                .map_err(message)?;
            Ok(json!({ "instances": rows(&document) }))
        }
    })
    .await
}

/// The tools/list scope source (W2b): GET /me once — the auth and
/// liveness gate AND the coverage oracle in one read — and take the
/// calling token's exact scope list from top-level `meta.scopes`
/// (#585: a PAT caller's list always renders; a zero-scope PAT
/// renders `[]`). Down from W2a's three reads: the write domains
/// (instances:write's boundary refusals) were never probeable, which
/// is why /me grew the list. The platform's own 403s stay the real
/// enforcement; this list is what tools/list may offer.
pub(crate) async fn me_scopes(base: Arc<str>, token: Token) -> Result<Vec<String>, ScopeError> {
    on_blocking(move || {
        // get_json, not get: `meta` rides the body's top level, outside
        // the crate's Document model — consume, don't extend the crate.
        ApiClient::new(&base, token)
            .get_json("/me")
            .map_err(|err| match err {
                // A dead token or a refused account — never a tool answer.
                err @ (ApiError::Unauthorized | ApiError::Forbidden(_)) => {
                    ScopeError::Auth(err.to_string())
                }
                other => ScopeError::Upstream(other.to_string()),
            })
            .and_then(|me| scopes_from_me(&me))
    })
    .await
}

/// The scope list out of a /me body. A PAT caller's answer always
/// carries `meta.scopes` (the route's own contract); an answer without
/// one is an upstream-shape surprise, so it fails loud — never a
/// silent "no tools", never a silent "all tools".
fn scopes_from_me(me: &Value) -> Result<Vec<String>, ScopeError> {
    let unexpected =
        || ScopeError::Upstream("/me did not render the calling token's meta.scopes".to_string());
    me["meta"]["scopes"]
        .as_array()
        .ok_or_else(unexpected)?
        .iter()
        .map(|scope| scope.as_str().map(str::to_owned).ok_or_else(unexpected))
        .collect()
}

// ---- the instance lifecycle writes (the CLI's writes.rs, verbatim
// sequences)

/// `instances_deploy`'s arguments as the wire sequence takes them
/// (the CLI's `DeployFlags`).
pub(crate) struct DeployWire {
    /// The app's URL slug — resolved to the app row first.
    pub app: String,
    /// A name for the new instance.
    pub name: Option<String>,
    /// CPU cores — the wire's decimal rides as a string ("0.5").
    pub cpu: Option<String>,
    pub memory_mb: Option<i64>,
    pub storage_gb: Option<i64>,
    /// The exact app version id; `None` takes the newest published.
    pub version: Option<String>,
}

/// The `instances deploy` sequence exactly: resolve the app by slug,
/// resolve the version (newest published unless one is given), POST
/// the create, PATCH the deploy. Refusals surface VERBATIM — the
/// funded-gate 403 says what it says (agents hit the same gate as the
/// UI, no exceptions); the one local rewrites are the CLI's friendly
/// 404 for an unknown app and the version-resolution refusals.
pub(crate) async fn instances_deploy(
    base: Arc<str>,
    token: Token,
    flags: DeployWire,
) -> Result<Value, String> {
    on_blocking_string(move || {
        safe_segment("app slug", &flags.app)?;
        let client = ApiClient::new(&base, token);
        let app = client
            .get(&format!("/apps/{}", flags.app))
            .map_err(|err| friendly_404(err, "app"))?;
        let app = one_resource(app, "app")?;
        let versions = client
            .get(&format!("/apps/{}/versions", app.id))
            .map_err(message)?;
        let (version_id, _label) =
            resolve_version(&flags.app, flags.version.as_deref(), versions.resources())?;

        // Only the given flags ride — absent keys take the version's
        // own defaults (catalog defaults apply server-side). env_vars
        // is never here: the create route's wire schema refuses it.
        let mut attrs = json!({"app_version_id": version_id});
        if let Some(name) = &flags.name {
            attrs["name"] = json!(name);
        }
        if let Some(cpu) = &flags.cpu {
            attrs["cpu_cores"] = json!(cpu);
        }
        if let Some(memory_mb) = flags.memory_mb {
            attrs["memory_mb"] = json!(memory_mb);
        }
        if let Some(storage_gb) = flags.storage_gb {
            attrs["storage_gb"] = json!(storage_gb);
        }
        let body = json!({"data": {"type": "instance", "attributes": attrs}});
        let created = client
            .send("POST", "/instances", Some(body.to_string()))
            .map_err(message)?;
        let instance = one_resource(created, "instance")?;
        let deploy_body =
            json!({"data": {"type": "instance", "id": instance.id, "attributes": {}}});
        let deployed = client
            .send(
                "PATCH",
                &format!("/instances/{}/deploy", instance.id),
                Some(deploy_body.to_string()),
            )
            .map_err(message)?;
        one_resource(deployed, "instance").map(|resource| with_id(&resource))
    })
    .await
}

/// `--version` must be one of the app's own (a foreign id would
/// deploy a different app's blueprint silently — the server derives
/// from the version row alone). Without it: the newest published (the
/// wire's own newest-first order); none published is a refusal. The
/// CLI's exact copy, choices listed.
fn resolve_version(
    slug: &str,
    flag: Option<&str>,
    versions: Vec<Resource>,
) -> Result<(String, String), String> {
    let catalog = |versions: &[Resource]| {
        versions
            .iter()
            .map(|version| format!("    {}  {}", version.id, version_label(version)))
            .collect::<Vec<_>>()
            .join("\n")
    };
    let take = |version: &Resource| (version.id.clone(), version_label(version));
    match flag {
        Some(id) => versions
            .iter()
            .find(|version| version.id == id)
            .map(take)
            .ok_or_else(|| {
                format!(
                    "version {id} is not a version of {slug} — pick one:\n{}",
                    catalog(&versions)
                )
            }),
        None => match versions.len() {
            0 => Err(format!("{slug} has no published versions")),
            _ => Ok(take(&versions[0])),
        },
    }
}

fn version_label(version: &Resource) -> String {
    version
        .attributes
        .get("version")
        .and_then(Value::as_str)
        .unwrap_or("-")
        .to_string()
}

/// `instances_stop` / `instances_start` — the PATCH pair; the
/// response row's status IS the transition.
pub(crate) async fn instances_lifecycle(
    base: Arc<str>,
    token: Token,
    id: String,
    verb: &'static str,
) -> Result<Value, String> {
    on_blocking_string(move || {
        safe_segment("instance id", &id)?;
        let body = json!({"data": {"type": "instance", "id": id, "attributes": {}}});
        let document = ApiClient::new(&base, token)
            .send(
                "PATCH",
                &format!("/instances/{id}/{verb}"),
                Some(body.to_string()),
            )
            .map_err(|err| friendly_404(err, "instance"))?;
        one_resource(document, "instance").map(|resource| with_id(&resource))
    })
    .await
}

/// `instances_destroy` — the DELETE; the wire answers the flat row
/// (a deployed instance lands `deleting` — the teardown runs async).
pub(crate) async fn instances_destroy(
    base: Arc<str>,
    token: Token,
    id: String,
) -> Result<Value, String> {
    on_blocking_string(move || {
        safe_segment("instance id", &id)?;
        ApiClient::new(&base, token)
            .send_json("DELETE", &format!("/instances/{id}"), None)
            .map_err(|err| friendly_404(err, "instance"))
    })
    .await
}

// ---- the backups verbs (the CLI's writes.rs, verbatim sequences)

/// The runs history read's query. `limit` is REQUIRED on the wire (the
/// route 400s "limit is required" without it); the status read wants
/// only the newest row.
pub(crate) const RUNS_PAGE_QUERY: &str = "?limit=1";

/// `backups_configure`'s arguments (the CLI's `ConfigureBackup`).
pub(crate) struct ConfigureBackupWire {
    pub instance: String,
    pub endpoint: String,
    pub bucket: String,
    pub prefix: Option<String>,
    pub access_key_id: String,
    pub retention_keep: Option<u8>,
    pub enabled: Option<bool>,
}

/// The `backups configure` create-or-update: read the row first; a
/// 404 (unconfigured — or a row a read couldn't return, which the
/// create arm's unique-constraint error then surfaces) posts a new
/// row, an existing row patches. Field validation is the server's;
/// its errors surface verbatim. `instance_id` never rides the create
/// body (the route's schema refuses a copy); the write-only secret
/// args (#503) are not parameters of this surface at all.
pub(crate) async fn backups_configure(
    base: Arc<str>,
    token: Token,
    flags: ConfigureBackupWire,
) -> Result<Value, String> {
    on_blocking_string(move || {
        safe_segment("instance id", &flags.instance)?;
        // The retention fence — the same 2..30 bound the resource
        // enforces, checked here so a bad value never rides the wire.
        if let Some(retention) = flags.retention_keep
            && !(2..=30).contains(&retention)
        {
            return Err(format!(
                "invalid retention_keep {retention}: keep between 2 and 30 snapshots"
            ));
        }
        let attrs = setting_attributes(&flags);
        let client = ApiClient::new(&base, token);
        match client.get(&format!("/instances/{}/backup-setting", flags.instance)) {
            // The create arm: instance_id rides the PATH, never the body.
            Err(ApiError::NotFound) => {
                let body = json!({"data": {"type": "backup_setting", "attributes": attrs}});
                let document = client
                    .send(
                        "POST",
                        &format!("/instances/{}/backup-setting", flags.instance),
                        Some(body.to_string()),
                    )
                    .map_err(message)?;
                one_resource(document, "backup setting").map(|resource| with_id(&resource))
            }
            // Any other read failure (forbidden, offline) passes through.
            Err(err) => Err(message(err)),
            Ok(document) => {
                let setting = one_resource(document, "backup setting")?;
                let body = json!({
                    "data": {
                        "type": "backup_setting",
                        "id": setting.id,
                        "attributes": attrs,
                    }
                });
                let updated = client
                    .send(
                        "PATCH",
                        &format!("/backup-settings/{}", setting.id),
                        Some(body.to_string()),
                    )
                    .map_err(message)?;
                one_resource(updated, "backup setting").map(|resource| with_id(&resource))
            }
        }
    })
    .await
}

/// The settings row's attributes: the required coordinates always;
/// prefix/retention/enabled only when given, so absent keys leave the
/// server's default (create) or the row's value (update) alone.
fn setting_attributes(flags: &ConfigureBackupWire) -> Value {
    let mut attrs = json!({
        "endpoint": flags.endpoint,
        "bucket": flags.bucket,
        "access_key_id": flags.access_key_id,
    });
    if let Some(prefix) = &flags.prefix {
        attrs["prefix"] = json!(prefix);
    }
    if let Some(retention) = flags.retention_keep {
        attrs["retention_keep"] = json!(retention);
    }
    if let Some(enabled) = flags.enabled {
        attrs["enabled"] = json!(enabled);
    }
    attrs
}

/// `backups_status` — the instance read first (a GET 404s a foreign or
/// missing id), then the settings row (or null — not configured) plus
/// the LATEST run. The runs read itself cannot name a foreign
/// instance: the policy FILTERS rows it can't see — a foreign id
/// answers 200 with an empty list, which is why the instance read
/// gates first.
pub(crate) async fn backups_status(
    base: Arc<str>,
    token: Token,
    instance: String,
) -> Result<Value, String> {
    on_blocking_string(move || {
        safe_segment("instance id", &instance)?;
        let client = ApiClient::new(&base, token);
        client
            .get(&format!("/instances/{instance}"))
            .map_err(|err| friendly_404(err, "instance"))?;
        let setting = match client.get(&format!("/instances/{instance}/backup-setting")) {
            Err(ApiError::NotFound) => None,
            Err(err) => return Err(message(err)),
            Ok(document) => Some(one_resource(document, "backup setting")?),
        };
        let runs = client
            .get(&format!(
                "/instances/{instance}/backup-runs{RUNS_PAGE_QUERY}"
            ))
            .map_err(message)?;
        let latest_run = runs.resources().into_iter().next();
        Ok(json!({
            "backup_setting": setting.as_ref().map(with_id).unwrap_or(Value::Null),
            "latest_run": latest_run.as_ref().map(with_id).unwrap_or(Value::Null),
        }))
    })
    .await
}

/// `backups_run` — the bodyless POST; the wire answers the flat run
/// row (it starts running; `backups_status` tracks the finish).
pub(crate) async fn backups_run(
    base: Arc<str>,
    token: Token,
    instance: String,
) -> Result<Value, String> {
    on_blocking_string(move || {
        safe_segment("instance id", &instance)?;
        ApiClient::new(&base, token)
            .send_json("POST", &format!("/instances/{instance}/backup-runs"), None)
            .map_err(|err| friendly_404(err, "instance"))
    })
    .await
}

/// `backups_restore` — the bodyless POST; the wire answers the flat
/// restore row. The run id must be the newest successful backup (the
/// server's own fence surfaces verbatim).
pub(crate) async fn backups_restore(
    base: Arc<str>,
    token: Token,
    instance: String,
    backup_run_id: String,
) -> Result<Value, String> {
    on_blocking_string(move || {
        safe_segment("instance id", &instance)?;
        safe_segment("backup run id", &backup_run_id)?;
        ApiClient::new(&base, token)
            .send_json(
                "POST",
                &format!("/instances/{instance}/backup-runs/{backup_run_id}/restore"),
                None,
            )
            .map_err(|err| friendly_404(err, "backup run"))
    })
    .await
}

// ---- the wallet reads (the CLI's reads.rs, verbatim routes)

/// `wallet_balance` — GET /organizations/{org}/wallet: the flat row.
pub(crate) async fn wallet_balance(
    base: Arc<str>,
    token: Token,
    org: String,
) -> Result<Value, String> {
    on_blocking_string(move || {
        safe_segment("organization id", &org)?;
        let document = ApiClient::new(&base, token)
            .get(&format!("/organizations/{org}/wallet"))
            .map_err(|err| friendly_404(err, "wallet"))?;
        one_resource(document, "wallet").map(|resource| with_id(&resource))
    })
    .await
}

/// `wallet_runway` — GET /organizations/{org}/wallet/runway. The
/// projection answers a bare JSON object, not a JSON:API envelope —
/// it IS the tool's structured content.
pub(crate) async fn wallet_runway(
    base: Arc<str>,
    token: Token,
    org: String,
) -> Result<Value, String> {
    on_blocking_string(move || {
        safe_segment("organization id", &org)?;
        ApiClient::new(&base, token)
            .get_json(&format!("/organizations/{org}/wallet/runway"))
            .map_err(|err| friendly_404(err, "wallet"))
    })
    .await
}

/// The ledger route's own default page size (LedgerEntry's
/// default_limit) — the wire REQUIRES page[limit], so a page always
/// names one.
pub(crate) const LEDGER_DEFAULT_LIMIT: u32 = 25;

/// `wallet_ledger` — the org's wallet first (the ledger route takes a
/// WALLET id), then the keyset page, newest first. The cursor is the
/// opaque `next_cursor` of a previous answer, passed through verbatim
/// (fenced for path-shaping characters — real cursors are
/// query-safe); `next_cursor` rides the answer while a next page
/// exists.
pub(crate) async fn wallet_ledger(
    base: Arc<str>,
    token: Token,
    org: String,
    cursor: Option<String>,
    limit: Option<u32>,
) -> Result<Value, String> {
    on_blocking_string(move || {
        safe_segment("organization id", &org)?;
        if let Some(cursor) = &cursor {
            safe_segment("ledger cursor", cursor)?;
        }
        // The limit fence: the wire 500s on page[limit]=0 — checked
        // here so a bad value never rides the wire.
        let Some(limit) = limit else {
            return ledger_page(&base, token, &org, cursor.as_deref(), LEDGER_DEFAULT_LIMIT);
        };
        if limit == 0 {
            return Err("invalid limit 0: must be at least 1".to_string());
        }
        ledger_page(&base, token, &org, cursor.as_deref(), limit)
    })
    .await
}

fn ledger_page(
    base: &Arc<str>,
    token: Token,
    org: &str,
    cursor: Option<&str>,
    limit: u32,
) -> Result<Value, String> {
    let client = ApiClient::new(base, token);
    let wallet = client
        .get(&format!("/organizations/{org}/wallet"))
        .map_err(|err| friendly_404(err, "wallet"))?;
    let wallet = one_resource(wallet, "wallet")?;
    let mut query = format!("?page[limit]={limit}&sort=-id");
    if let Some(cursor) = cursor {
        query.push_str("&page[after]=");
        query.push_str(cursor);
    }
    let document = client
        .get(&format!("/wallets/{}/ledger-entries{query}", wallet.id))
        .map_err(message)?;
    let mut answer = json!({ "entries": rows(&document) });
    if let Some(next) = next_after_cursor(&document) {
        answer["next_cursor"] = json!(next);
    }
    Ok(answer)
}

/// The next page's opaque cursor, lifted out of the document's own
/// `links.next` URL (raw query value) — the `next_cursor` answer
/// field's source. None when there is no next page (or the link omits
/// the cursor).
fn next_after_cursor(document: &Document) -> Option<String> {
    let next = document.links.as_ref()?.get("next")?.as_str()?;
    let query = next.split_once('?')?.1;
    query
        .split('&')
        .find_map(|pair| pair.strip_prefix("page[after]="))
        .map(str::to_owned)
}

/// `topup` — the panel's top-up URL (the canonical origin + the
/// panel's live route). No API call: the tool is a pointer for the
/// human, not a verb on the wire.
pub(crate) fn topup_url(base: &str) -> String {
    format!("{}/billing/topup", base.trim_end_matches('/'))
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
        let row = apps_list(base(&server), token()).await.unwrap();
        assert_eq!(row["apps"][0]["slug"], "wordpress");
        assert_eq!(row["apps"][0]["id"], "1");
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
        let wrapped = instances_list(base(&list), token()).await.unwrap();
        assert_eq!(wrapped["instances"][0]["id"], "i1");
        assert_eq!(wrapped["instances"][0]["status"], "running");

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
        let wrapped = instances_status(base(&server), token(), None)
            .await
            .unwrap();
        assert_eq!(wrapped, json!({"instances": []}));
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

    // ---- the /me scope source (W2b: one read, meta.scopes)

    fn me_doc_with_scopes(scopes: &[&str]) -> String {
        envelope(json!({
            "data": {"type": "user", "id": "01H",
                     "attributes": {"email": "me@example.com", "platform_role": "user"}},
            "meta": {"scopes": scopes}
        }))
    }

    #[tokio::test]
    async fn me_scopes_returns_the_calling_tokens_exact_list() {
        let server = serve(&[(
            "/api/v1/me",
            200,
            &me_doc_with_scopes(&["instances:read", "instances:write", "wallet:read"]),
        )]);
        let scopes = me_scopes(base(&server), token()).await.unwrap();
        assert_eq!(scopes, ["instances:read", "instances:write", "wallet:read"]);
        // Exactly one upstream read per tools/list — the head count is
        // the audit line (W2a probed three).
        assert_eq!(server.head_count(), 1);
    }

    #[tokio::test]
    async fn a_zero_scope_token_answers_the_empty_list() {
        // A minted "no grants" fact, not an omission (#585's contract).
        let server = serve(&[("/api/v1/me", 200, &me_doc_with_scopes(&[]))]);
        let scopes = me_scopes(base(&server), token()).await.unwrap();
        assert!(scopes.is_empty());
    }

    #[tokio::test]
    async fn a_me_without_meta_scopes_fails_loud_as_an_upstream_shape_error() {
        // A session-shaped /me answer (no meta) is not a token
        // caller's answer — never a silent "no tools" (nor "all").
        let server = serve(&[("/api/v1/me", 200, &envelope(me_doc()))]);
        let err = me_scopes(base(&server), token()).await.unwrap_err();
        assert!(matches!(err, ScopeError::Upstream(_)), "got: {err:?}");
        assert!(
            err_message(&err).contains("meta.scopes"),
            "message: {}",
            err_message(&err)
        );
        // A non-string scope entry is the same loud surprise.
        let body = envelope(json!({
            "data": me_doc()["data"].clone(),
            "meta": {"scopes": [7]}
        }));
        let server = serve(&[("/api/v1/me", 200, &body)]);
        let err = me_scopes(base(&server), token()).await.unwrap_err();
        assert!(matches!(err, ScopeError::Upstream(_)));
    }

    #[tokio::test]
    async fn a_me_401_is_an_auth_error_not_unavailable() {
        // The token is dead — the same -32600 path as a dead /me gate,
        // never "the API is unavailable".
        let body = envelope(json!({"errors": [
            {"status": "401", "title": "Unauthorized"}
        ]}));
        let server = serve(&[("/api/v1/me", 401, &body)]);
        let err = me_scopes(base(&server), token()).await.unwrap_err();
        assert!(matches!(err, ScopeError::Auth(_)), "got: {err:?}");
        assert_eq!(
            err_message(&err),
            "not signed in or token revoked (fluxvale auth login)"
        );
    }

    #[tokio::test]
    async fn a_dead_platform_on_me_is_an_upstream_error_with_the_verbatim_line() {
        let body = &envelope(json!({"errors": [
            {"status": "500", "title": "Internal Server Error"}
        ]}));
        let server = serve(&[("/api/v1/me", 500, body)]);
        let err = me_scopes(base(&server), token()).await.unwrap_err();
        assert!(matches!(err, ScopeError::Upstream(_)));
    }

    #[tokio::test]
    async fn a_forbidden_account_is_an_auth_error_too() {
        let body = &envelope(json!({"errors": [
            {"status": "403", "title": "Forbidden", "detail": "denied"}
        ]}));
        let server = serve(&[("/api/v1/me", 403, body)]);
        let err = me_scopes(base(&server), token()).await.unwrap_err();
        assert!(matches!(err, ScopeError::Auth(_)));
    }

    #[tokio::test]
    async fn transient_failures_are_upstream_errors_with_the_verbatim_line() {
        let server = serve(&[("/api/v1/me", 429, &envelope(json!({"errors": []})))]);
        let err = me_scopes(base(&server), token()).await.unwrap_err();
        assert!(matches!(err, ScopeError::Upstream(_)));
        assert_eq!(err_message(&err), "rate limited");
    }

    fn err_message(err: &ScopeError) -> String {
        match err {
            ScopeError::Auth(message) | ScopeError::Upstream(message) => message.clone(),
        }
    }

    // ---- the write verbs: the sequences, the bodies, the refusals.
    // A scripted server (the CLI's pattern): one canned response per
    // connection, every request head+body captured.

    struct Script {
        base_url: String,
        requests: Arc<std::sync::Mutex<Vec<String>>>,
    }

    fn script(responses: Vec<String>) -> Script {
        use std::collections::VecDeque;
        use std::io::{Read as _, Write as _};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let requests = Arc::new(std::sync::Mutex::new(Vec::new()));
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
                let _ = stream.write_all(response.as_bytes());
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

    fn respond(status_line: &str, body: &str) -> String {
        let mut response = format!("HTTP/1.1 {status_line}\r\n");
        response.push_str(&format!("Content-Length: {}\r\n", body.len()));
        response.push_str("Connection: close\r\n\r\n");
        response.push_str(body);
        response
    }

    fn respond_envelope(status_line: &str, body: serde_json::Value) -> String {
        respond(status_line, &body.to_string())
    }

    fn not_found() -> String {
        respond(
            "404 Not Found",
            r#"{"errors":[{"status":"404","title":"Not Found"}]}"#,
        )
    }

    fn captured_requests(server: &Script) -> Vec<String> {
        server
            .requests
            .lock()
            .unwrap()
            .iter()
            .map(|raw| raw.to_lowercase())
            .collect()
    }

    fn app_row(slug: &str, app_id: &str) -> serde_json::Value {
        json!({
            "type": "app", "id": app_id,
            "attributes": {"id": app_id, "name": "Forgejo", "slug": slug}
        })
    }

    fn version_row(version_id: &str, number: &str) -> serde_json::Value {
        json!({
            "type": "app_version", "id": version_id,
            "attributes": {"id": version_id, "version": number}
        })
    }

    fn instance_row(id: &str, status: &str) -> serde_json::Value {
        json!({
            "type": "instance", "id": id,
            "attributes": {
                "id": id, "name": "my forgejo", "slug": "my-forgejo-a1",
                "status": status, "cpu_cores": "0.5"
            }
        })
    }

    fn deploy_wire() -> DeployWire {
        DeployWire {
            app: "forgejo".into(),
            name: Some("my forgejo".into()),
            cpu: None,
            memory_mb: None,
            storage_gb: None,
            version: None,
        }
    }

    fn deploy_responses() -> Vec<String> {
        vec![
            respond_envelope("200 OK", json!({"data": app_row("forgejo", "app1")})),
            respond_envelope(
                "200 OK",
                json!({"data": [version_row("v2", "1.2"), version_row("v1", "1.0")]}),
            ),
            respond_envelope(
                "201 Created",
                json!({"data": instance_row("i1", "pending")}),
            ),
            respond_envelope("200 OK", json!({"data": instance_row("i1", "deploying")})),
        ]
    }

    #[tokio::test]
    async fn deploy_walks_app_versions_create_deploy_in_order() {
        let server = script(deploy_responses());
        let row = instances_deploy(base_of(&server), token(), deploy_wire())
            .await
            .unwrap();
        assert_eq!(row["status"], "deploying");
        assert_eq!(row["id"], "i1");

        let requests = captured_requests(&server);
        assert_eq!(requests.len(), 4, "app, versions, create, deploy");
        assert!(
            requests[0].starts_with("get /api/v1/apps/forgejo http/1.1"),
            "req0: {}",
            requests[0]
        );
        assert!(
            requests[1].starts_with("get /api/v1/apps/app1/versions http/1.1"),
            "req1: {}",
            requests[1]
        );
        assert!(
            requests[2].starts_with("post /api/v1/instances http/1.1"),
            "req2: {}",
            requests[2]
        );
        assert!(
            requests[3].starts_with("patch /api/v1/instances/i1/deploy http/1.1"),
            "req3: {}",
            requests[3]
        );
        // The create body: the NEWEST published version (the wire's own
        // order), the given name, no env_vars and no unset flags.
        assert!(
            requests[2].contains("\"app_version_id\":\"v2\""),
            "req2: {}",
            requests[2]
        );
        assert!(
            requests[2].contains("\"name\":\"my forgejo\""),
            "req2: {}",
            requests[2]
        );
        assert!(!requests[2].contains("env_vars"), "req2: {}", requests[2]);
        assert!(
            !requests[2].contains("cpu_cores"),
            "unset flags stay out: {}",
            requests[2]
        );
    }

    #[tokio::test]
    async fn deploy_carries_only_the_given_resource_flags() {
        let server = script(deploy_responses());
        let flags = DeployWire {
            cpu: Some("1.5".into()),
            memory_mb: Some(1024),
            storage_gb: Some(5),
            name: None,
            ..deploy_wire()
        };
        instances_deploy(base_of(&server), token(), flags)
            .await
            .unwrap();
        let create = &captured_requests(&server)[2];
        assert!(create.contains("\"cpu_cores\":\"1.5\""), "create: {create}");
        assert!(create.contains("\"memory_mb\":1024"), "create: {create}");
        assert!(create.contains("\"storage_gb\":5"), "create: {create}");
        assert!(!create.contains("\"name\""), "create: {create}");
    }

    #[tokio::test]
    async fn deploy_with_a_version_takes_exactly_that_id() {
        let server = script(deploy_responses());
        let flags = DeployWire {
            version: Some("v1".into()),
            ..deploy_wire()
        };
        instances_deploy(base_of(&server), token(), flags)
            .await
            .unwrap();
        let create = &captured_requests(&server)[2];
        assert!(
            create.contains("\"app_version_id\":\"v1\""),
            "create: {create}"
        );
    }

    #[tokio::test]
    async fn deploy_refusals_surface_their_own_words() {
        // Unknown app: the CLI's friendly 404 line, nothing else sent.
        let server = script(vec![not_found()]);
        let err = instances_deploy(base_of(&server), token(), deploy_wire())
            .await
            .unwrap_err();
        assert_eq!(err, "no such app (or it's not yours)");
        assert_eq!(captured_requests(&server).len(), 1);

        // No published versions.
        let server = script(vec![
            respond_envelope("200 OK", json!({"data": app_row("forgejo", "app1")})),
            respond_envelope("200 OK", json!({"data": []})),
        ]);
        let err = instances_deploy(base_of(&server), token(), deploy_wire())
            .await
            .unwrap_err();
        assert_eq!(err, "forgejo has no published versions");

        // A foreign version id: the refusal lists the app's own.
        let server = script(vec![
            respond_envelope("200 OK", json!({"data": app_row("forgejo", "app1")})),
            respond_envelope("200 OK", json!({"data": [version_row("v2", "1.2")]})),
        ]);
        let err = instances_deploy(
            base_of(&server),
            token(),
            DeployWire {
                version: Some("other-apps-version".into()),
                ..deploy_wire()
            },
        )
        .await
        .unwrap_err();
        assert!(
            err.contains("version other-apps-version is not a version of forgejo"),
            "err: {err}"
        );
        assert!(err.contains("v2"), "the choices ride the error: {err}");
    }

    #[tokio::test]
    async fn deploy_funded_gate_403_surfaces_verbatim() {
        // The money posture: agents hit the same gate as the UI.
        let server = script(vec![
            respond_envelope("200 OK", json!({"data": app_row("forgejo", "app1")})),
            respond_envelope("200 OK", json!({"data": [version_row("v2", "1.2")]})),
            respond(
                "403 Forbidden",
                r#"{"errors":[{"status":"403","title":"Forbidden","detail":"the org wallet needs funds — top up at /billing/topup"}]}"#,
            ),
        ]);
        let err = instances_deploy(base_of(&server), token(), deploy_wire())
            .await
            .unwrap_err();
        assert_eq!(
            err,
            "403 Forbidden: the org wallet needs funds — top up at /billing/topup"
        );
    }

    #[tokio::test]
    async fn stop_and_start_patch_the_verbs() {
        for (verb, status) in [("stop", "stopped"), ("start", "starting")] {
            let server = script(vec![respond_envelope(
                "200 OK",
                json!({"data": instance_row("i1", status)}),
            )]);
            let row = instances_lifecycle(base_of(&server), token(), "i1".into(), verb)
                .await
                .unwrap();
            assert_eq!(row["status"], status);
            let requests = captured_requests(&server);
            assert!(
                requests[0].starts_with(&format!("patch /api/v1/instances/i1/{verb} http/1.1")),
                "req0: {}",
                requests[0]
            );
            assert!(
                requests[0]
                    .contains("{\"data\":{\"attributes\":{},\"id\":\"i1\",\"type\":\"instance\"}}"),
                "req0: {}",
                requests[0]
            );
        }
    }

    #[tokio::test]
    async fn lifecycle_and_destroy_404s_read_the_friendly_instance_line() {
        for verb in ["stop", "start"] {
            let server = script(vec![not_found()]);
            let err = instances_lifecycle(base_of(&server), token(), "i9".into(), verb)
                .await
                .unwrap_err();
            assert_eq!(err, "no such instance (or it's not yours)");
        }
        let server = script(vec![not_found()]);
        let err = instances_destroy(base_of(&server), token(), "i9".into())
            .await
            .unwrap_err();
        assert_eq!(err, "no such instance (or it's not yours)");
    }

    #[tokio::test]
    async fn destroy_deletes_and_answers_the_flat_row() {
        let server = script(vec![respond(
            "200 OK",
            r#"{"id":"i1","name":"my forgejo","slug":"my-forgejo-a1","status":"deleting"}"#,
        )]);
        let row = instances_destroy(base_of(&server), token(), "i1".into())
            .await
            .unwrap();
        assert_eq!(row["status"], "deleting");
        assert_eq!(row["id"], "i1");
        let requests = captured_requests(&server);
        assert!(
            requests[0].starts_with("delete /api/v1/instances/i1 http/1.1"),
            "req0: {}",
            requests[0]
        );
    }

    fn setting_row() -> serde_json::Value {
        json!({
            "type": "backup_setting", "id": "set1",
            "attributes": {
                "id": "set1", "instance_id": "i1",
                "endpoint": "https://e.example", "bucket": "bucket",
                "access_key_id": "KEY", "retention_keep": 7, "enabled": true
            }
        })
    }

    fn configure_wire() -> ConfigureBackupWire {
        ConfigureBackupWire {
            instance: "i1".into(),
            endpoint: "https://e.example".into(),
            bucket: "bucket".into(),
            prefix: Some("fluxvale/app".into()),
            access_key_id: "KEY".into(),
            retention_keep: None,
            enabled: None,
        }
    }

    #[tokio::test]
    async fn configure_creates_through_the_404_arm_without_instance_id() {
        let server = script(vec![
            not_found(),
            respond_envelope("201 Created", json!({"data": setting_row()})),
        ]);
        let row = backups_configure(base_of(&server), token(), configure_wire())
            .await
            .unwrap();
        assert_eq!(row["id"], "set1");

        let requests = captured_requests(&server);
        assert!(
            requests[0].starts_with("get /api/v1/instances/i1/backup-setting http/1.1"),
            "req0: {}",
            requests[0]
        );
        assert!(
            requests[1].starts_with("post /api/v1/instances/i1/backup-setting http/1.1"),
            "req1: {}",
            requests[1]
        );
        assert!(
            requests[1].contains("\"endpoint\":\"https://e.example\""),
            "req1: {}",
            requests[1]
        );
        assert!(
            requests[1].contains("\"prefix\":\"fluxvale/app\""),
            "req1: {}",
            requests[1]
        );
        // instance_id never rides the create body — the path is the
        // only intake.
        assert!(
            !requests[1].contains("instance_id"),
            "req1: {}",
            requests[1]
        );
    }

    #[tokio::test]
    async fn configure_patches_the_existing_row() {
        let server = script(vec![
            respond_envelope("200 OK", json!({"data": setting_row()})),
            respond_envelope("200 OK", json!({"data": setting_row()})),
        ]);
        backups_configure(base_of(&server), token(), configure_wire())
            .await
            .unwrap();
        let requests = captured_requests(&server);
        assert!(
            requests[1].starts_with("patch /api/v1/backup-settings/set1 http/1.1"),
            "req1: {}",
            requests[1]
        );
        // Neither enabled flag given: absent from the payload, so a
        // paused row stays paused.
        assert!(!requests[1].contains("enabled"), "req1: {}", requests[1]);
    }

    #[tokio::test]
    async fn configure_fences_a_bad_retention_before_the_wire() {
        // A dead-port origin: a wire call would die with transport
        // noise, so the fence's message proves it fired first.
        let dead: Arc<str> = Arc::from("http://127.0.0.1:1");
        let err = backups_configure(
            dead,
            token(),
            ConfigureBackupWire {
                retention_keep: Some(31),
                ..configure_wire()
            },
        )
        .await
        .unwrap_err();
        assert_eq!(
            err,
            "invalid retention_keep 31: keep between 2 and 30 snapshots"
        );
    }

    #[tokio::test]
    async fn configure_refusals_pass_through_verbatim() {
        // A scope 403 on the read must NOT read as "not configured".
        let server = script(vec![respond(
            "403 Forbidden",
            r#"{"errors":[{"status":"403","title":"Forbidden","detail":"token lacks the backups:write scope"}]}"#,
        )]);
        let err = backups_configure(base_of(&server), token(), configure_wire())
            .await
            .unwrap_err();
        assert_eq!(err, "403 Forbidden: token lacks the backups:write scope");

        // The create arm's validation words surface verbatim too.
        let server = script(vec![
            not_found(),
            respond(
                "422 Unprocessable Entity",
                r#"{"errors":[{"status":"422","title":"Unprocessable Entity","detail":"endpoint must be an http:// or https:// URL with a host and no path"}]}"#,
            ),
        ]);
        let err = backups_configure(
            base_of(&server),
            token(),
            ConfigureBackupWire {
                endpoint: "ftp://nope".into(),
                ..configure_wire()
            },
        )
        .await
        .unwrap_err();
        assert!(
            err.contains("endpoint must be an http:// or https:// URL"),
            "err: {err}"
        );
    }

    fn succeeded_run() -> serde_json::Value {
        json!({
            "type": "backup_run", "id": "r9",
            "attributes": {
                "id": "r9", "instance_id": "i1", "kind": "manual",
                "status": "succeeded", "snapshot_id": "aaaa",
                "started_at": "2026-11-04T21:00:00Z", "finished_at": "2026-11-04T21:02:00Z"
            }
        })
    }

    #[tokio::test]
    async fn status_reads_the_instance_then_the_setting_then_the_latest_run() {
        let server = script(vec![
            respond_envelope("200 OK", json!({"data": instance_row("i1", "running")})),
            respond_envelope("200 OK", json!({"data": setting_row()})),
            respond_envelope("200 OK", json!({"data": [succeeded_run()]})),
        ]);
        let answer = backups_status(base_of(&server), token(), "i1".into())
            .await
            .unwrap();
        assert_eq!(answer["backup_setting"]["bucket"], "bucket");
        assert_eq!(answer["latest_run"]["status"], "succeeded");

        let requests = captured_requests(&server);
        assert_eq!(requests.len(), 3, "instance, setting, runs");
        assert!(
            requests[0].starts_with("get /api/v1/instances/i1 http/1.1"),
            "req0: {}",
            requests[0]
        );
        // limit is REQUIRED on the wire — the route 400s without it.
        assert!(
            requests[2].starts_with("get /api/v1/instances/i1/backup-runs?limit=1 http/1.1"),
            "req2: {}",
            requests[2]
        );
    }

    #[tokio::test]
    async fn status_unconfigured_and_foreign_arms() {
        // Unconfigured (the caller's instance): nulls, after the
        // instance read passed.
        let server = script(vec![
            respond_envelope("200 OK", json!({"data": instance_row("i1", "running")})),
            not_found(),
            respond_envelope("200 OK", json!({"data": []})),
        ]);
        let answer = backups_status(base_of(&server), token(), "i1".into())
            .await
            .unwrap();
        assert_eq!(answer, json!({"backup_setting": null, "latest_run": null}));

        // A foreign instance: the INSTANCE read 404s — the friendly
        // line, and nothing else is read (the runs index would have
        // answered an empty 200 for a foreign id; the instance get is
        // what names it).
        let server = script(vec![not_found()]);
        let err = backups_status(base_of(&server), token(), "i9".into())
            .await
            .unwrap_err();
        assert_eq!(err, "no such instance (or it's not yours)");
        assert_eq!(
            captured_requests(&server).len(),
            1,
            "stop after the instance read"
        );
    }

    #[tokio::test]
    async fn run_posts_bodyless_and_answers_the_run_row() {
        let server = script(vec![respond(
            "201 Created",
            r#"{"id":"r9","kind":"manual","status":"running","instance_id":"i1"}"#,
        )]);
        let row = backups_run(base_of(&server), token(), "i1".into())
            .await
            .unwrap();
        assert_eq!(row["status"], "running");
        let requests = captured_requests(&server);
        assert!(
            requests[0].starts_with("post /api/v1/instances/i1/backup-runs http/1.1"),
            "req0: {}",
            requests[0]
        );
        assert!(
            !requests[0].contains("content-type:"),
            "bodyless POST must not claim a media type: {}",
            requests[0]
        );

        // The operation's own refusals surface verbatim.
        let server = script(vec![respond(
            "400 Bad Request",
            r#"{"errors":[{"detail":"backups are not configured for this instance"}]}"#,
        )]);
        let err = backups_run(base_of(&server), token(), "i1".into())
            .await
            .unwrap_err();
        assert!(
            err.contains("backups are not configured for this instance"),
            "err: {err}"
        );
    }

    #[tokio::test]
    async fn restore_posts_the_restore_route_and_answers_the_row() {
        let server = script(vec![respond(
            "201 Created",
            r#"{"id":"r10","kind":"restore","status":"running","instance_id":"i1","restored_from":"r9"}"#,
        )]);
        let row = backups_restore(
            base_of(&server),
            token(),
            "i1".into(),
            "11111111-2222-3333-4444-555555555555".into(),
        )
        .await
        .unwrap();
        assert_eq!(row["kind"], "restore");
        assert_eq!(row["restored_from"], "r9");
        let requests = captured_requests(&server);
        assert!(
            requests[0].starts_with(
                "post /api/v1/instances/i1/backup-runs/11111111-2222-3333-4444-555555555555/restore http/1.1"
            ),
            "req0: {}",
            requests[0]
        );

        // The server's own fence words (not-the-latest, foreign run).
        let server = script(vec![respond(
            "400 Bad Request",
            r#"{"errors":[{"detail":"is not the latest successful backup — restore targets the latest one"}]}"#,
        )]);
        let err = backups_restore(
            base_of(&server),
            token(),
            "i1".into(),
            "11111111-2222-3333-4444-555555555555".into(),
        )
        .await
        .unwrap_err();
        assert!(
            err.contains("not the latest successful backup"),
            "err: {err}"
        );
    }

    fn wallet_row() -> serde_json::Value {
        json!({
            "type": "wallet", "id": "w1",
            "attributes": {
                "id": "w1", "organization_id": "01JORG1",
                "balance": 400, "paywall_waived": false
            }
        })
    }

    #[tokio::test]
    async fn wallet_balance_reads_the_org_wallet_row() {
        let server = script(vec![respond_envelope(
            "200 OK",
            json!({"data": wallet_row()}),
        )]);
        let row = wallet_balance(base_of(&server), token(), "01JORG1".into())
            .await
            .unwrap();
        assert_eq!(row["id"], "w1");
        assert_eq!(row["balance"], 400);
        let requests = captured_requests(&server);
        assert!(
            requests[0].starts_with("get /api/v1/organizations/01jorg1/wallet http/1.1"),
            "req0: {}",
            requests[0]
        );

        // A foreign org 404 reads the friendly wallet line.
        let server = script(vec![not_found()]);
        let err = wallet_balance(base_of(&server), token(), "ghost".into())
            .await
            .unwrap_err();
        assert_eq!(err, "no such wallet (or it's not yours)");
    }

    #[tokio::test]
    async fn wallet_runway_answers_the_bare_projection() {
        let server = script(vec![respond(
            "200 OK",
            r#"{"balance_cents":400,"burn_micro_cents_per_hour":0,"runway_hours":"infinity"}"#,
        )]);
        let map = wallet_runway(base_of(&server), token(), "01JORG1".into())
            .await
            .unwrap();
        assert_eq!(map["balance_cents"], 400);
        assert_eq!(map["runway_hours"], "infinity");
    }

    #[tokio::test]
    async fn wallet_ledger_rides_the_org_wallet_then_the_keyset_query() {
        let ledger_body = json!({
            "data": [
                {"type": "ledger_entry", "id": "e2",
                 "attributes": {"id": "e2", "amount": -5, "type": "usage", "reason": "compute"}},
                {"type": "ledger_entry", "id": "e1",
                 "attributes": {"id": "e1", "amount": 500, "type": "purchase", "reason": "topup"}}
            ],
            "links": {"next": "/api/v1/wallets/w1/ledger-entries?page[limit]=2&sort=-id&page[after]=Q1VCUw"}
        });
        let server = script(vec![
            respond_envelope("200 OK", json!({"data": wallet_row()})),
            respond_envelope("200 OK", ledger_body),
        ]);
        let answer = wallet_ledger(base_of(&server), token(), "01JORG1".into(), None, Some(2))
            .await
            .unwrap();
        assert_eq!(answer["entries"][0]["id"], "e2");
        assert_eq!(answer["entries"][1]["reason"], "topup");
        assert_eq!(answer["next_cursor"], "Q1VCUw");

        let requests = captured_requests(&server);
        assert!(
            requests[1].starts_with(
                "get /api/v1/wallets/w1/ledger-entries?page[limit]=2&sort=-id http/1.1"
            ),
            "req1: {}",
            requests[1]
        );

        // The cursor rides verbatim once given (and the fence refuses
        // path-shaping cursors before any wire call).
        let server = script(vec![
            respond_envelope("200 OK", json!({"data": wallet_row()})),
            respond_envelope("200 OK", json!({"data": [], "links": {}})),
        ]);
        let answer = wallet_ledger(
            base_of(&server),
            token(),
            "01JORG1".into(),
            Some("Q1VCUw".into()),
            None,
        )
        .await
        .unwrap();
        assert!(answer.get("next_cursor").is_none(), "answer: {answer}");
        let requests = captured_requests(&server);
        assert!(
            requests[1].starts_with(
                "get /api/v1/wallets/w1/ledger-entries?page[limit]=25&sort=-id&page[after]=q1vcuw http/1.1"
            ),
            "req1: {}",
            requests[1]
        );

        let dead: Arc<str> = Arc::from("http://127.0.0.1:1");
        assert_eq!(
            wallet_ledger(dead.clone(), token(), "o".into(), None, Some(0))
                .await
                .unwrap_err(),
            "invalid limit 0: must be at least 1"
        );
        assert_eq!(
            wallet_ledger(dead, token(), "o".into(), Some("a/b".into()), None)
                .await
                .unwrap_err(),
            "invalid ledger cursor: a/b"
        );
    }

    #[test]
    fn topup_url_joins_the_origin_and_the_panel_route() {
        assert_eq!(
            topup_url("https://fluxvale.com"),
            "https://fluxvale.com/billing/topup"
        );
        assert_eq!(
            topup_url("http://127.0.0.1:4000/"),
            "http://127.0.0.1:4000/billing/topup"
        );
    }

    #[test]
    fn resolve_version_picks_the_newest_and_fences_foreign_ids() {
        let versions = |ids: &[(&str, &str)]| {
            serde_json::from_value::<Document>(json!({
                "data": ids.iter().map(|(id, number)| version_row(id, number)).collect::<Vec<_>>()
            }))
            .unwrap()
            .resources()
        };
        let versions = versions(&[("v2", "1.2"), ("v1", "1.0")]);
        // No flag: the first row (the wire's newest-first order).
        assert_eq!(
            resolve_version("forgejo", None, versions.clone()).unwrap(),
            ("v2".into(), "1.2".into())
        );
        // A flag: exactly that id.
        assert_eq!(
            resolve_version("forgejo", Some("v1"), versions.clone()).unwrap(),
            ("v1".into(), "1.0".into())
        );
        // A foreign id: the refusal lists the app's own.
        let err = resolve_version("forgejo", Some("other"), versions).unwrap_err();
        assert!(
            err.contains("version other is not a version of forgejo"),
            "err: {err}"
        );
        assert!(err.contains("v2"), "err: {err}");
        // None published.
        assert_eq!(
            resolve_version("forgejo", None, vec![]).unwrap_err(),
            "forgejo has no published versions"
        );
        // A row without a version attribute labels with the dash
        // rather than failing.
        let unlabeled = vec![Resource {
            r#type: "app_version".into(),
            id: "v3".into(),
            attributes: json!({}),
        }];
        assert_eq!(
            resolve_version("forgejo", None, unlabeled).unwrap(),
            ("v3".into(), "-".into())
        );
    }

    fn base_of(server: &Script) -> Arc<str> {
        Arc::from(server.base_url.as_str())
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
