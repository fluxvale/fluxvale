//! The upstream calls: the tools' `/api/v1` verbs. The deploy/lifecycle/
//! backup/wallet/topup calls mirror the CLI's reads.rs/writes.rs
//! (same routes, same params, same bodies, the same flat `id`-hoisted
//! row shape); the #771 parity tools (resize, gateway, custom domains,
//! Pocket ID wiring) ride the same `fluxvale-api` client and the same
//! wire shapes. Errors surface VERBATIM — the crate preserves the
//! JSON:API detail and neither layer rewrites it; the one local
//! addition is the CLI's friendly 404 for a missing single thing.
//! Calls run on the blocking pool (the client crate is ureq).

use fluxvale_api::{ApiClient, ApiError, Document, Resource, Token};
use serde_json::{Value, json};
use std::sync::Arc;

/// The error shapes the tools/list scope source answers.
#[derive(Debug)]
pub(crate) enum ScopeError {
    /// 401/403 from /me — the token is dead or the account refused;
    /// the caller reconfigures its token.
    Auth(String),
    /// A 200 /me without `meta.scopes` (or with a non-string entry) —
    /// not a transient outage but a shape mismatch: the caller is not
    /// a PAT (a session cookie's /me), or the platform predates #585.
    /// Its own error line, never "the API is unavailable".
    Shape(String),
    /// Anything else (429, 5xx, transport) — transient or upstream;
    /// surfaced verbatim, no retries.
    Upstream(String),
}

// ---- the async surface: per-request client, blocking pool

/// `GET /me` — the legacy PAT initialize/discover gate: 401/403
/// refuse the connection. OAuth access tokens are validated by the
/// middleware's `me_scopes` call instead (#766).
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

/// One organization row as the tools report it: the switcher's key set
/// (id/slug/name), never org-internal fields.
#[derive(Debug, Clone, serde::Serialize)]
pub(crate) struct OrganizationRow {
    pub id: String,
    pub slug: Option<String>,
    pub name: Option<String>,
}

impl OrganizationRow {
    /// The provider's diagnostic shape: `Acme (acme)`.
    fn label(&self) -> String {
        match (&self.name, &self.slug) {
            (Some(name), Some(slug)) => format!("{name} ({slug})"),
            (Some(name), None) => name.clone(),
            (None, Some(slug)) => format!("({slug})"),
            (None, None) => self.id.clone(),
        }
    }
}

/// GET /organizations — the actor's memberships, the org-resolution
/// source for #770's optional `organization` arguments.
pub(crate) fn organizations(client: &ApiClient) -> Result<Vec<OrganizationRow>, String> {
    let document = client.get("/organizations").map_err(message)?;
    Ok(document
        .resources()
        .iter()
        .map(|org| OrganizationRow {
            id: org.id.clone(),
            slug: org
                .attributes
                .get("slug")
                .and_then(Value::as_str)
                .map(str::to_owned),
            name: org
                .attributes
                .get("name")
                .and_then(Value::as_str)
                .map(str::to_owned),
        })
        .collect())
}

/// An org named by id or slug, from the actor's own list (the server
/// member-fences the rest). An unknown name refuses listing the
/// choices — never a silent pick (the provider's rule).
pub(crate) fn find_organization(client: &ApiClient, spec: &str) -> Result<OrganizationRow, String> {
    find_in(&organizations(client)?, spec)
}

/// [`find_organization`] over an already-fetched list (the onboarding
/// read composes /me + orgs once and must not re-read them).
fn find_in(orgs: &[OrganizationRow], spec: &str) -> Result<OrganizationRow, String> {
    orgs.iter()
        .find(|org| org.id == spec || org.slug.as_deref() == Some(spec))
        .cloned()
        .ok_or_else(|| {
            format!(
                "no organization with id or slug \"{spec}\". Yours: {}",
                org_list(orgs)
            )
        })
}

/// The deploy/resolve rule (the Terraform provider's): an explicit
/// name wins, else the sole membership; several without a name refuse
/// listing them — never a silent pick.
pub(crate) fn resolve_organization(
    client: &ApiClient,
    spec: Option<&str>,
) -> Result<OrganizationRow, String> {
    if let Some(spec) = spec {
        return find_organization(client, spec);
    }
    let orgs = organizations(client)?;
    match orgs.len() {
        0 => Err(
            "no organization to deploy into — the token belongs to no organization; \
             create one with organizations_create"
                .to_string(),
        ),
        1 => Ok(orgs[0].clone()),
        _ => Err(format!(
            "multiple organizations — pass `organization` (id or slug): {}",
            org_list(&orgs)
        )),
    }
}

fn org_list(orgs: &[OrganizationRow]) -> String {
    orgs.iter()
        .map(OrganizationRow::label)
        .collect::<Vec<_>>()
        .join(", ")
}

/// `organizations_create` — POST /organizations (#770): the actor
/// path's own action (#408), so the server's policies (actor present,
/// below the org cap) and the reserved-slug validation are the gate.
/// The answer is the switcher's key set.
pub(crate) async fn organizations_create(
    base: Arc<str>,
    token: Token,
    name: String,
    slug: String,
) -> Result<Value, String> {
    on_blocking_string(move || {
        let body = json!({
            "data": {
                "type": "organization",
                "attributes": {"name": name, "slug": slug}
            }
        });
        let document = ApiClient::new(&base, token)
            .send("POST", "/organizations", Some(body.to_string()))
            .map_err(message)?;
        one_resource(document, "organization").map(|resource| with_id(&resource))
    })
    .await
}

/// `pricing_quote` — GET /pricing/quote (#770): the platform's one
/// pricing operation over the wire. The cents are computed
/// server-side; this client never does price arithmetic.
pub(crate) async fn pricing_quote(
    base: Arc<str>,
    token: Token,
    cpu: String,
    memory_mb: i64,
    storage_gb: i64,
) -> Result<Value, String> {
    safe_query_value("cpu cores", &cpu)?;
    on_blocking_string(move || {
        ApiClient::new(&base, token)
            .get_json(&format!(
                "/pricing/quote?cpu_cores={cpu}&memory_mb={memory_mb}&storage_gb={storage_gb}"
            ))
            .map_err(message)
    })
    .await
}

/// `onboarding_status` — composed from existing reads (#770): /me, the
/// orgs, the chosen org's wallet + runway, and the instance count. No
/// new state; the next step is derived, never stored.
///
/// The org choice follows the deploy rule: an explicit name wins, a
/// sole membership falls back, several without a name stay unchosen
/// (`choose_org`) — never a silent pick.
pub(crate) async fn onboarding_status(
    base: Arc<str>,
    token: Token,
    organization: Option<String>,
) -> Result<Value, String> {
    on_blocking_string(move || {
        let client = ApiClient::new(&base, token);
        let me = client.get("/me").map_err(message)?;
        let user = one_resource(me, "user")?;
        let email = user.attributes.get("email").and_then(Value::as_str);
        let orgs = organizations(&client)?;

        let chosen = match organization.as_deref() {
            Some(spec) => Some(find_in(&orgs, spec)?),
            None if orgs.len() == 1 => Some(orgs[0].clone()),
            None => None,
        };

        let wallet = match &chosen {
            Some(org) => wallet_summary(&client, &org.id)?,
            None => Value::Null,
        };

        let balance = match &wallet {
            Value::Object(map) => map
                .get("balance_cents")
                .and_then(Value::as_i64)
                .unwrap_or(0),
            _ => 0,
        };

        // The count names the org in play when one is chosen; with no
        // org chosen (several memberships) it stays the actor-wide
        // read — the `choose_org` answer needs "you have resources
        // somewhere", not a per-org guess.
        let instance_count = match &chosen {
            Some(org) => {
                let document = client
                    .get(&format!("/organizations/{}/instances", org.id))
                    .map_err(message)?;
                document.resources().len()
            }
            None => {
                let document = client.get("/instances").map_err(message)?;
                document.resources().len()
            }
        };

        let next_step = if chosen.is_none() {
            "choose_org"
        } else if balance <= 0 {
            "fund"
        } else if instance_count == 0 {
            "deploy"
        } else {
            "connect_domain"
        };

        let funding = chosen.as_ref().and_then(|org| funding_url(&base, org));

        Ok(json!({
            "account": {
                "id": user.id,
                "email": email,
                "verified": email.is_some(),
                "username": user.attributes.get("username"),
            },
            "organizations": orgs,
            "organization": chosen.map(|org| json!({
                "id": org.id, "slug": org.slug, "name": org.name,
            })).unwrap_or(Value::Null),
            "wallet": wallet,
            "instance_count": instance_count,
            "next_step": next_step,
            "funding_url": funding,
        }))
    })
    .await
}

/// The chosen org's wallet + runway, shaped for the onboarding answer.
/// A 404 is the honest "no wallet row yet" (a team org bills lazily) —
/// reported as null, with the caller reading it as an unfunded org;
/// every other failure surfaces verbatim.
fn wallet_summary(client: &ApiClient, org_id: &str) -> Result<Value, String> {
    let document = match client.get(&format!("/organizations/{org_id}/wallet")) {
        Ok(document) => document,
        Err(ApiError::NotFound) => return Ok(Value::Null),
        Err(err) => return Err(message(err)),
    };
    let wallet = one_resource(document, "wallet")?;
    let balance_cents = wallet
        .attributes
        .get("balance")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    // The runway read is the wallet route's sibling; a wallet without
    // one is the same unpriced shape the wallet read's nulls carry.
    let runway = match client.get_json(&format!("/organizations/{org_id}/wallet/runway")) {
        Ok(runway) => runway,
        Err(ApiError::NotFound) => Value::Null,
        Err(err) => return Err(message(err)),
    };
    Ok(json!({
        "balance_cents": balance_cents,
        "paywall_waived": wallet.attributes.get("paywall_waived"),
        "burn_micro_cents_per_hour": runway["burn_micro_cents_per_hour"],
        "runway_hours": runway["runway_hours"],
    }))
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

/// `apps_show` — GET /apps/{slug}, then the app's versions: one
/// catalog app with its `versions` (each carrying the default
/// allocation and `monthly_cents` — the price an agent quotes before
/// deploy) and, from #770, the newest version's agent manual under
/// `version` (env/first-run/backing contract plus the server-computed
/// default-size quote). The app row alone cannot answer "what will
/// this cost"; the manual is where the agent looks for the deploy
/// contract. Names and defaults only, never an instance's values.
pub(crate) async fn apps_show(base: Arc<str>, token: Token, slug: String) -> Result<Value, String> {
    safe_segment("app slug", &slug)?;
    on_blocking_string(move || {
        let client = ApiClient::new(&base, token);
        let document = client
            .get(&format!("/apps/{slug}"))
            .map_err(|err| friendly_404(err, "app"))?;
        let app = one_resource(document, "app")?;
        let versions = client
            .get(&format!("/apps/{}/versions", app.id))
            .map_err(message)?;
        let mut row = with_id(&app);
        row["versions"] = rows(&versions);
        // #770: the newest version as the agent manual, beside the
        // versions list (the bare deploy takes the same first row).
        let newest = versions.resources().into_iter().next();
        let version = match newest {
            Some(version) => version_manual(&client, &version)?,
            None => Value::Null,
        };
        if let Value::Object(map) = &mut row {
            map.insert("version".to_string(), version);
        }
        Ok(row)
    })
    .await
}

/// One version row as the manual: the deploy contract's fields plus
/// the default-size quote. `default_env_vars` stays off (its values
/// are operator-owned, and the manual's contract is the configurable
/// half); secrets have no catalog values to carry.
fn version_manual(client: &ApiClient, version: &Resource) -> Result<Value, String> {
    let mut manual = serde_json::Map::new();
    manual.insert("id".to_string(), json!(version.id));
    for key in [
        "version",
        "default_cpu_cores",
        "default_memory_mb",
        "default_storage_gb",
        "configurable_env_vars",
        "first_run",
        "backing_services",
        "oidc_wiring",
    ] {
        if let Some(value) = version.attributes.get(key) {
            manual.insert(key.to_string(), value.clone());
        }
    }
    manual.insert("pricing".to_string(), default_pricing(client, &version.id)?);
    Ok(Value::Object(manual))
}

/// The default-size quote — the version's own rates from the platform:
/// the recommended Size row plus the storage axis at the version's
/// default (`Pricing.version_rates/1`), the figure settlement charges a
/// default-size instance. Server-computed, never a client formula.
fn default_pricing(client: &ApiClient, version_id: &str) -> Result<Value, String> {
    safe_segment("version id", version_id)?;
    let quote = client
        .get_json(&format!("/app-versions/{version_id}/quote"))
        .map_err(message)?;
    Ok(json!({
        "monthly_cents": quote["monthly_cents"],
        "stopped_monthly_cents": quote["stopped_monthly_cents"],
        "monthly": quote["monthly"],
        "stopped": quote["stopped"],
    }))
}

/// `instances_list` — GET /instances, or the org-scoped collection
/// (#770) when an organization is named. The name resolves through the
/// actor's own memberships (id or slug) — an unknown name refuses with
/// the choices, never a silent empty list.
pub(crate) async fn instances_list(
    base: Arc<str>,
    token: Token,
    organization: Option<String>,
) -> Result<Value, String> {
    on_blocking_string(move || {
        let client = ApiClient::new(&base, token);
        match organization {
            None => {
                let document = client.get("/instances").map_err(message)?;
                Ok(json!({ "instances": rows(&document) }))
            }
            Some(spec) => {
                let org = find_organization(&client, &spec)?;
                let document = client
                    .get(&format!("/organizations/{}/instances", org.id))
                    .map_err(message)?;
                Ok(json!({ "instances": rows(&document) }))
            }
        }
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

/// `terraform_import_bundle` — discover the org's live estate and
/// render the same three files the CLI writes. Read-only: the shared
/// module makes GET calls only, and the tool returns the contents
/// instead of touching a filesystem.
pub(crate) async fn terraform_import_bundle(
    base: Arc<str>,
    token: Token,
    organization: String,
    api_url: Option<String>,
) -> Result<Value, String> {
    on_blocking_string(move || {
        let client = ApiClient::new(&base, token);
        let bundle = match api_url.as_deref() {
            Some(url) => fluxvale_api::terraform::bundle_with(&client, &organization, url),
            // No implicit upstream origin: it can be an in-cluster
            // service name the caller's machine cannot resolve.
            None => fluxvale_api::terraform::bundle_default(&client, &organization),
        }
        .map_err(|err| err.to_string())?;
        Ok(json!({
            "organization": bundle.organization,
            "files": bundle
                .files
                .iter()
                .map(|file| json!({"path": file.name, "content": file.contents}))
                .collect::<Vec<_>>(),
        }))
    })
    .await
}

/// `gateway` — status/attach/detach over the org's single gateway
/// (#771). The org resolves like the deploy's (id/slug, or the sole
/// membership); attach/detach re-read the status after the pairing, so
/// the answer always shows what the gateway became.
pub(crate) async fn gateway(
    base: Arc<str>,
    token: Token,
    action: GatewayAction,
    organization: Option<String>,
    instance_id: Option<String>,
) -> Result<Value, String> {
    on_blocking_string(move || {
        // The action's own required argument fails before any read.
        let instance_id = match action {
            GatewayAction::Status => None,
            GatewayAction::Attach | GatewayAction::Detach => {
                let instance_id = instance_id
                    .as_deref()
                    .ok_or_else(|| "instance_id is required for attach and detach".to_string())?;
                safe_segment("instance id", instance_id)?;
                Some(instance_id.to_string())
            }
        };

        let client = ApiClient::new(&base, token);
        let org = resolve_organization(&client, organization.as_deref())?;
        let org_row = json!({"id": &org.id, "slug": &org.slug, "name": &org.name});

        match action {
            GatewayAction::Status => {
                let gateway = read_gateway(&client, &org.id)?;
                let message = gateway.is_none().then_some(
                    "no access gateway for this organization — enable one in the panel's Access tab",
                );
                Ok(json!({
                    "organization": org_row,
                    "gateway": gateway.unwrap_or(Value::Null),
                    "message": message,
                }))
            }
            GatewayAction::Attach => {
                let instance_id = instance_id.expect("validated for attach/detach");
                let gateway_id = org_gateway_id(&client, &org)?;
                let body = json!({"data": {"instance_id": instance_id}});
                let attachment = client
                    .send_json(
                        "POST",
                        &format!("/access-gateways/{gateway_id}/attachments"),
                        Some(body.to_string()),
                    )
                    .map_err(friendly_pairing_404)?;
                let (status, status_error) = gateway_after_pairing(&client, &org.id);
                Ok(json!({
                    "organization": org_row,
                    "gateway": status,
                    "status_error": status_error,
                    "attachment": attachment,
                }))
            }
            GatewayAction::Detach => {
                let instance_id = instance_id.expect("validated for attach/detach");
                let gateway_id = org_gateway_id(&client, &org)?;
                let answer = client
                    .send_json(
                        "DELETE",
                        &format!("/access-gateways/{gateway_id}/attachments/{instance_id}"),
                        None,
                    )
                    .map_err(friendly_pairing_404)?;
                let (status, status_error) = gateway_after_pairing(&client, &org.id);
                Ok(json!({
                    "organization": org_row,
                    "gateway": status,
                    "status_error": status_error,
                    "detached": true,
                    "result": answer,
                }))
            }
        }
    })
    .await
}

/// The org's gateway row and its id; the "no gateway" refusal names
/// the org so a multi-org caller knows which one to enable.
fn org_gateway_id(client: &ApiClient, org: &OrganizationRow) -> Result<String, String> {
    let gateway = read_gateway(client, &org.id)?.ok_or_else(|| {
        format!(
            "no access gateway for {} — enable one in the panel's Access tab",
            org.label()
        )
    })?;
    let gateway_id = gateway["id"]
        .as_str()
        .ok_or_else(|| "the gateway row carries no id".to_string())?
        .to_string();
    safe_segment("gateway id", &gateway_id)?;
    Ok(gateway_id)
}

/// The pairing's re-read, split so a committed attach/detach is never
/// hidden behind a status-read failure: the pairing row is the answer,
/// and any read failure rides beside it.
fn gateway_after_pairing(client: &ApiClient, org_id: &str) -> (Value, Value) {
    match read_gateway(client, org_id) {
        Ok(Some(gateway)) => (gateway, Value::Null),
        Ok(None) => (
            Value::Null,
            json!("the gateway status read answered not found after the pairing"),
        ),
        Err(message) => (Value::Null, json!(message)),
    }
}

/// The org's gateway row, or `None` for the honest 404 absence.
fn read_gateway(client: &ApiClient, org_id: &str) -> Result<Option<Value>, String> {
    match client.get(&format!("/organizations/{org_id}/access-gateway")) {
        Ok(document) => {
            one_resource(document, "access gateway").map(|resource| Some(with_id(&resource)))
        }
        Err(ApiError::NotFound) => Ok(None),
        Err(err) => Err(message(err)),
    }
}

/// The platform's attach/detach 404 can be the gateway or the
/// instance, so the friendly line names both rather than guessing.
fn friendly_pairing_404(err: ApiError) -> String {
    match err {
        ApiError::NotFound => "no such gateway or instance (or it's not yours)".to_string(),
        other => message(other),
    }
}

/// `custom_domain` — register/verify/list/remove over the access-domain
/// routes (#771). Every reported row carries the honest serving state
/// (`live`, `healthy`, and a machine-readable `reason_code` plus
/// prose). A gateway status-read failure rides beside the row as
/// `serving_error` — it never hides a committed registration.
pub(crate) async fn custom_domain(
    base: Arc<str>,
    token: Token,
    action: CustomDomainAction,
    organization: Option<String>,
    id: Option<String>,
    domain: Option<String>,
) -> Result<Value, String> {
    on_blocking_string(move || {
        let client = ApiClient::new(&base, token);

        match action {
            CustomDomainAction::List => {
                let org = resolve_organization(&client, organization.as_deref())?;
                let org_row = json!({"id": &org.id, "slug": &org.slug, "name": &org.name});
                let document = client
                    .get(&format!("/organizations/{}/access-domains", org.id))
                    .map_err(message)?;
                let (gateway, gateway_error) = gateway_view(&client, &org.id);
                let domains = document
                    .resources()
                    .iter()
                    .map(|resource| {
                        annotate_domain(
                            with_id(resource),
                            gateway.as_ref(),
                            gateway_error.as_deref(),
                        )
                    })
                    .collect::<Vec<_>>();
                let mut answer = json!({"organization": org_row, "domains": domains});
                if let Some(err) = &gateway_error {
                    answer["serving_error"] = json!(err);
                }
                Ok(answer)
            }
            CustomDomainAction::Create => {
                let domain = domain.ok_or_else(|| "domain is required for create".to_string())?;
                let org = resolve_organization(&client, organization.as_deref())?;
                let body = json!({"data": {"type": "access_domain", "attributes": {
                    "domain": domain,
                    "organization_id": org.id,
                }}});
                let document = client
                    .send("POST", "/access-domains", Some(body.to_string()))
                    .map_err(message)?;
                let resource = one_resource(document, "access domain")?;
                let (gateway, gateway_error) = gateway_view(&client, &org.id);
                Ok(with_serving_error(
                    annotate_domain(
                        with_id(&resource),
                        gateway.as_ref(),
                        gateway_error.as_deref(),
                    ),
                    gateway_error.as_deref(),
                ))
            }
            CustomDomainAction::Verify => {
                let id = id.ok_or_else(|| "id is required for verify and delete".to_string())?;
                safe_segment("domain id", &id)?;
                let document = client
                    .get(&format!("/access-domains/{id}"))
                    .map_err(|err| friendly_404(err, "domain"))?;
                let resource = one_resource(document, "access domain")?;
                // The row names its org; the gateway is that org's,
                // never the caller-named one (a multi-org caller can
                // pass any own org, but the domain's claim lives in
                // its owner org).
                let org_id = resource
                    .attributes
                    .get("organization_id")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "the domain row carries no organization_id".to_string())?;
                safe_segment("organization id", org_id)?;
                let (gateway, gateway_error) = gateway_view(&client, org_id);
                Ok(with_serving_error(
                    annotate_domain(
                        with_id(&resource),
                        gateway.as_ref(),
                        gateway_error.as_deref(),
                    ),
                    gateway_error.as_deref(),
                ))
            }
            CustomDomainAction::Delete => {
                let id = id.ok_or_else(|| "id is required for verify and delete".to_string())?;
                safe_segment("domain id", &id)?;
                let row = client
                    .send_json("DELETE", &format!("/access-domains/{id}"), None)
                    .map_err(|err| friendly_404(err, "domain"))?;
                Ok(json!({"removed": true, "domain": annotate_removed(row)}))
            }
        }
    })
    .await
}

/// The gateway read for annotation: the row when readable, and the
/// failure beside it. A status outage must not hide a registered row.
fn gateway_view(client: &ApiClient, org_id: &str) -> (Option<Value>, Option<String>) {
    match read_gateway(client, org_id) {
        Ok(gateway) => (gateway, None),
        Err(message) => (None, Some(message)),
    }
}

fn domain_state(row: &Value) -> &str {
    row.get("state").and_then(Value::as_str).unwrap_or("")
}

/// The serving verdict. `live` is whether the domain serves right now;
/// `reason_code` names why (or how). Resolution order: platform kind,
/// blocking states, gateway read failure, gateway presence, gateway
/// serving state, the claim (proof the token worked, checked before
/// the nullable token stamp), the token stamp, then unclaimed.
/// `needs_attention` keeps serving while its retained claim is active
/// — the cert is still valid and the routes still stand — so its live
/// value follows the claim rather than the state; `healthy` stays
/// false.
fn domain_serving(
    row: &Value,
    gateway: Option<&Value>,
    gateway_error: Option<&str>,
) -> (&'static str, &'static str, bool) {
    // The platform row is fleet-served (the wildcard already covers
    // it); it is never claimed and has no issuance to wait on.
    if row.get("kind").and_then(Value::as_str) == Some("platform") {
        return (
            "platform",
            "the platform domain is served by the fleet wildcard; instance addresses use it directly",
            true,
        );
    }

    match domain_state(row) {
        "pending" => (
            "pending",
            "verification is certificate issuance; no certificate is issued yet",
            false,
        ),
        "failed" => (
            "failed",
            "issuance did not complete — remove the row and re-register after fixing the DNS delegation",
            false,
        ),
        "suspended" => (
            "suspended",
            "the domain is parked and serves nothing",
            false,
        ),
        "verified" | "needs_attention" => {
            if gateway_error.is_some() {
                return (
                    "unknown",
                    "the gateway status could not be read; the serving state is unknown",
                    false,
                );
            }
            let Some(gateway) = gateway else {
                return (
                    "no_gateway",
                    "the organization has no access gateway to claim the domain",
                    false,
                );
            };
            if gateway["state"].as_str() != Some("active") {
                return (
                    "gateway_not_serving",
                    "the organization's gateway is not serving right now, so its retained claim cannot route",
                    false,
                );
            }
            let live = claimed(gateway, row);
            if domain_state(row) == "needs_attention" {
                return (
                    "needs_attention",
                    "the certificate is not ready; the domain serves only while its retained claim is active",
                    live,
                );
            }
            match live {
                true => (
                    "claimed",
                    "the gateway has claimed the domain; hostnames under it serve from private attached instances",
                    true,
                ),
                false if gateway["api_token_set"].as_bool() == Some(false) => (
                    "no_api_token",
                    "the gateway holds no Tailscale API token, so the domain cannot be claimed",
                    false,
                ),
                false => (
                    "unclaimed",
                    "the certificate is issued, but the gateway has not claimed the domain; claiming is not a self-serve surface yet",
                    false,
                ),
            }
        }
        _ => ("unknown", "the domain is not serving", false),
    }
}

fn claimed(gateway: &Value, row: &Value) -> bool {
    let domain = row.get("domain").and_then(Value::as_str);
    let claimed = gateway.get("claimed_domains").and_then(Value::as_array);
    match (domain, claimed) {
        (Some(domain), Some(domains)) => domains.iter().any(|entry| entry.as_str() == Some(domain)),
        _ => false,
    }
}

fn annotate_domain(mut row: Value, gateway: Option<&Value>, gateway_error: Option<&str>) -> Value {
    let (reason_code, reason, live) = domain_serving(&row, gateway, gateway_error);
    let verified = domain_state(&row) == "verified";
    let healthy = matches!(reason_code, "platform") || verified;
    if let Value::Object(map) = &mut row {
        map.insert("verified".to_string(), json!(verified));
        map.insert("healthy".to_string(), json!(healthy));
        map.insert("live".to_string(), json!(live));
        map.insert(
            "serving".to_string(),
            json!({"live": live, "healthy": healthy, "reason_code": reason_code, "reason": reason}),
        );
    }
    row
}

/// A committed row plus the annotation read's failure, when there was
/// one — the registration is the answer, the failure rides beside it.
fn with_serving_error(mut row: Value, gateway_error: Option<&str>) -> Value {
    if let (Some(err), Value::Object(map)) = (gateway_error, &mut row) {
        map.insert("serving_error".to_string(), json!(err));
    }
    row
}

/// A removed domain keeps its identity fields and says so — no serving
/// annotation to misread as a live row.
fn annotate_removed(mut row: Value) -> Value {
    if let Value::Object(map) = &mut row {
        map.insert("live".to_string(), json!(false));
        map.insert("healthy".to_string(), json!(false));
        map.insert(
            "serving".to_string(),
            json!({"live": false, "healthy": false, "reason_code": "removed", "reason": "the domain row is gone"}),
        );
    }
    row
}

/// `sso` — status/connect over the instance's Pocket ID wiring (#771).
/// Identifier fields only: the minted client secret lives in the
/// instance's env and never rides the API or this tool. The success
/// shape is projected explicitly, so a future wire field cannot leak
/// through by accident.
pub(crate) async fn sso(
    base: Arc<str>,
    token: Token,
    action: SsoAction,
    instance_id: String,
    pocket_id_instance_id: Option<String>,
) -> Result<Value, String> {
    on_blocking_string(move || {
        safe_segment("instance id", &instance_id)?;
        if action == SsoAction::Connect {
            let pocket_id_instance_id = pocket_id_instance_id
                .as_deref()
                .ok_or_else(|| "pocket_id_instance_id is required for connect".to_string())?;
            safe_segment("pocket id instance id", pocket_id_instance_id)?;
        }
        let client = ApiClient::new(&base, token);

        match action {
            SsoAction::Status => {
                // The wiring read is member-scoped and a missing row
                // means unwired — but a foreign/mistyped instance also
                // 404s there. Prove the instance first so `wired:false`
                // only ever describes an instance the caller can see.
                client
                    .get(&format!("/instances/{instance_id}"))
                    .map_err(|err| friendly_404(err, "instance"))?;
                match client.get(&format!("/instances/{instance_id}/pocket-id-wiring")) {
                    Ok(document) => {
                        let resource = one_resource(document, "pocket id wiring")?;
                        Ok(json!({
                            "instance_id": instance_id,
                            "wired": true,
                            "wiring": project_wiring(with_id(&resource)),
                        }))
                    }
                    Err(ApiError::NotFound) => Ok(json!({
                        "instance_id": instance_id,
                        "wired": false,
                        "wiring": Value::Null,
                    })),
                    Err(err) => Err(message(err)),
                }
            }
            SsoAction::Connect => {
                let pocket_id_instance_id = pocket_id_instance_id.expect("validated for connect");
                let body = json!({"data": {"pocket_id_instance_id": pocket_id_instance_id}});
                let connected = client
                    .send_json(
                        "POST",
                        &format!("/instances/{instance_id}/connect-pocketid"),
                        Some(body.to_string()),
                    )
                    .map_err(|err| friendly_404(err, "instance"))?;
                let wiring = project_wiring(connected);
                // Read back the durable row; a 404 here (a create
                // committed but invisible) still answers the connect
                // row. Any other read failure rides beside the
                // committed row — the connect already happened, and a
                // retry would re-mint.
                let (read_back, status_error) =
                    match client.get(&format!("/instances/{instance_id}/pocket-id-wiring")) {
                        Ok(document) => match one_resource(document, "pocket id wiring") {
                            Ok(resource) => (project_wiring(with_id(&resource)), Value::Null),
                            Err(message) => (wiring.clone(), json!(message)),
                        },
                        Err(ApiError::NotFound) => (wiring.clone(), Value::Null),
                        Err(err) => (wiring.clone(), json!(message(err))),
                    };
                Ok(json!({
                    "instance_id": instance_id,
                    "wired": true,
                    "wiring": read_back,
                    "status_error": status_error,
                }))
            }
        }
    })
    .await
}

/// The wiring's wire row projected to identifiers only. `env_vars`
/// and any future secret-bearing field are deliberately absent.
fn project_wiring(row: Value) -> Value {
    json!({
        "id": row.get("id").cloned().unwrap_or(Value::Null),
        "instance_id": row.get("instance_id").cloned().unwrap_or(Value::Null),
        "pocket_id_instance_id": row.get("pocket_id_instance_id").cloned().unwrap_or(Value::Null),
        "pocket_id_client_id": row.get("pocket_id_client_id").cloned().unwrap_or(Value::Null),
        "pocket_id_secret_id": row.get("pocket_id_secret_id").cloned().unwrap_or(Value::Null),
        "wired_at": row.get("wired_at").cloned().unwrap_or(Value::Null),
    })
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
    me_grant(base, token).await.map(|grant| grant.scopes)
}

/// The `/me` token grant: the exact scope list plus the RFC 8707
/// resource the token was issued for (None for a PAT, whose rows have
/// no audience binding).
pub(crate) struct MeGrant {
    pub scopes: Vec<String>,
    pub resource: Option<String>,
}

/// `gateway`'s verbs (#771) — one tool over the org's single gateway.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub(crate) enum GatewayAction {
    /// Read the org's gateway row (the default).
    Status,
    /// Pair a private instance to the gateway.
    Attach,
    /// Unpair an instance (idempotent).
    Detach,
}

/// `custom_domain`'s verbs (#771).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub(crate) enum CustomDomainAction {
    /// The org's registered domains, with their honest serving state.
    List,
    /// Register a domain (`:pending` until certificate issuance).
    Create,
    /// Re-read one domain's verification state (issuance is the verifier).
    Verify,
    /// Remove a domain (the server refuses a domain still serving hostnames).
    Delete,
}

/// `sso`'s verbs (#771).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub(crate) enum SsoAction {
    /// The instance's wiring row, or `wired: false`.
    Status,
    /// Mint a Pocket ID OIDC client and wire the instance's env.
    Connect,
}

/// `GET /me` for the OAuth resource-server path: scopes + audience in
/// one read. The middleware compares `resource` to this server's public
/// URL; a mismatch is an invalid token for this audience.
pub(crate) async fn me_grant(base: Arc<str>, token: Token) -> Result<MeGrant, ScopeError> {
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
            .and_then(|me| grant_from_me(&me))
    })
    .await
}

/// The scope list out of a /me body. A PAT caller's answer always
/// carries `meta.scopes` (the route's own contract); an answer without
/// one is a shape mismatch with its OWN error line — never "the API is
/// unavailable", never a silent "no tools", never a silent "all
/// tools".
fn grant_from_me(me: &Value) -> Result<MeGrant, ScopeError> {
    let unexpected = || {
        ScopeError::Shape(
            "unexpected /me answer: no meta.scopes — not a PAT caller, or the platform predates #585"
                .to_string(),
        )
    };
    let scopes = me["meta"]["scopes"]
        .as_array()
        .ok_or_else(unexpected)?
        .iter()
        .map(|scope| scope.as_str().map(str::to_owned).ok_or_else(unexpected))
        .collect::<Result<Vec<_>, _>>()?;

    let resource = match &me["meta"]["resource"] {
        Value::Null => None,
        Value::String(resource) => Some(resource.clone()),
        _not_a_string => return Err(unexpected()),
    };

    Ok(MeGrant { scopes, resource })
}

// ---- the instance lifecycle writes (the CLI's writes.rs, verbatim
// sequences)

/// `instances_deploy`'s arguments as the wire sequence takes them
/// (the CLI's `DeployFlags`, with `name` promoted to required — the
/// create route refuses a nameless body: the attribute is
/// allow_nil?-false and DeriveFromAppVersion doesn't set it, so the
/// CLI's optional `--name` is a phantom default, not a wire truth).
pub(crate) struct DeployWire {
    /// The app's URL slug — resolved to the app row first.
    pub app: String,
    /// A name for the new instance — required (you name it).
    pub name: String,
    /// CPU cores — the wire's decimal rides as a string ("0.5").
    pub cpu: Option<String>,
    pub memory_mb: Option<i64>,
    pub storage_gb: Option<i64>,
    /// The exact app version id; `None` takes the newest (the
    /// versions route's own newest-first order).
    pub version: Option<String>,
    /// The create's env vars. Write-only: the API never echoes them,
    /// and nothing here logs or renders the values.
    pub env: Option<std::collections::BTreeMap<String, String>>,
    /// #770: the org id/slug the instance lands in. `None` resolves to
    /// the actor's sole organization (several without a name refuse).
    pub organization: Option<String>,
}

/// The `instances deploy` sequence exactly: resolve the app by slug,
/// resolve the version (newest unless one is given), POST the create,
/// PATCH the deploy. Refusals surface VERBATIM — the funded-gate 403
/// says what it says (agents hit the same gate as the UI, no
/// exceptions); the one local rewrites are the CLI's friendly 404 for
/// an unknown app and the version-resolution refusals.
pub(crate) async fn instances_deploy(
    base: Arc<str>,
    token: Token,
    flags: DeployWire,
) -> Result<Value, String> {
    on_blocking_string(move || {
        safe_segment("app slug", &flags.app)?;
        let client = ApiClient::new(&base, token);
        // #770: the org resolves BEFORE the app read — a nameless
        // multi-org deploy refuses with the choices instead of
        // silently landing in the personal org (the provider's rule).
        let org = resolve_organization(&client, flags.organization.as_deref())?;
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
        // is the create's write-only input (#482): present replaces
        // the whole map before the catalog defaults merge under it.
        // name always rides: the wire requires it; the org rides the
        // create's own member-fenced argument (#770).
        let mut attrs = json!({
            "app_version_id": version_id,
            "name": flags.name,
            "organization_id": org.id,
        });
        if let Some(cpu) = &flags.cpu {
            attrs["cpu_cores"] = json!(cpu);
        }
        if let Some(memory_mb) = flags.memory_mb {
            attrs["memory_mb"] = json!(memory_mb);
        }
        if let Some(storage_gb) = flags.storage_gb {
            attrs["storage_gb"] = json!(storage_gb);
        }
        if let Some(env) = &flags.env {
            attrs["env_vars"] = json!(env);
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

/// `instances_configure` — PATCH /instances/{id}/env (#731,
/// ADR-0052): the explicit set/remove merge. The response is the
/// standard detail row; values never ride either direction. An empty
/// patch is refused locally (nothing to merge, nothing to say).
pub(crate) async fn instances_configure(
    base: Arc<str>,
    token: Token,
    id: String,
    set: Option<std::collections::BTreeMap<String, String>>,
    remove: Option<Vec<String>>,
) -> Result<Value, String> {
    on_blocking_string(move || {
        safe_segment("instance id", &id)?;
        let set = set.unwrap_or_default();
        let remove = remove.unwrap_or_default();
        if set.is_empty() && remove.is_empty() {
            return Err("nothing to change — pass at least one env key to set or remove".into());
        }
        let mut attrs = json!({});
        if !set.is_empty() {
            attrs["set"] = json!(set);
        }
        if !remove.is_empty() {
            attrs["remove"] = json!(remove);
        }
        let body = json!({"data": {"type": "instance", "id": id, "attributes": attrs}});
        let updated = ApiClient::new(&base, token)
            .send(
                "PATCH",
                &format!("/instances/{id}/env"),
                Some(body.to_string()),
            )
            .map_err(|err| friendly_404(err, "instance"))?;
        one_resource(updated, "instance").map(|resource| with_id(&resource))
    })
    .await
}

/// `--version` must be one of the app's own (a foreign id would
/// deploy a different app's blueprint silently — the server derives
/// from the version row alone). Without it: the newest — the
/// versions route's own sort (version string, newest first), no
/// published filter; an empty list is a refusal. The refusal copy is
/// the CLI's exact line (which says "published" — CLI parity, not the
/// wire's truth).
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
        lifecycle(&ApiClient::new(&base, token), &id, verb)
    })
    .await
}

/// The lifecycle PATCH over an existing client (the resize's
/// stop/start limbs share it).
fn lifecycle(client: &ApiClient, id: &str, verb: &str) -> Result<Value, String> {
    lifecycle_maybe(client, id, verb).map_err(|(_, message)| message)
}

/// The lifecycle PATCH with the "may have landed" bit kept: a 5xx or
/// transport failure can follow a committed scale, while a 4xx guard
/// proves nothing changed. The stop leg uses it to decide whether a
/// row observed stopped is ours to restart.
fn lifecycle_maybe(client: &ApiClient, id: &str, verb: &str) -> Result<Value, (bool, String)> {
    let body = json!({"data": {"type": "instance", "id": id, "attributes": {}}});
    match client.send(
        "PATCH",
        &format!("/instances/{id}/{verb}"),
        Some(body.to_string()),
    ) {
        Ok(document) => match one_resource(document, "instance") {
            Ok(resource) => Ok(with_id(&resource)),
            // A 200 whose body we cannot read: the write may have
            // committed, so the stop's row must be re-read before
            // anything restarts it.
            Err(message) => Err((true, message)),
        },
        Err(err) => {
            let may_have_landed = match &err {
                // The platform's error documents carry their status;
                // a 4xx proves the guard refused before any scale. A
                // 5xx, a statusless body, or a transport failure may
                // follow a committed stop.
                ApiError::Transport(_) => true,
                ApiError::Api(message) => !message.starts_with('4'),
                _ => false,
            };
            Err((may_have_landed, friendly_404(err, "instance")))
        }
    }
}

/// `instances_resize` — the stopped-first sequence (ADR-0043): a
/// running row is stopped, the allocation PATCHed while stopped, then
/// started. The response always carries the step reached and the
/// instance's actual state; a resize failure restarts the instance
/// only when this call stopped it, and reports both outcomes plus the
/// final state — no instance this call stopped is left silently
/// stranded. An already-stopped row stays stopped on a failed resize
/// (this call never changed its state). A server refusal (`sleeping`,
/// `starting`, a storage shrink, a missing expansion capability) is
/// the server's line, verbatim.
pub(crate) async fn instances_resize(
    base: Arc<str>,
    token: Token,
    id: String,
    cpu: Option<String>,
    memory_mb: Option<i64>,
    storage_gb: Option<i64>,
) -> Result<Value, String> {
    on_blocking_string(move || {
        safe_segment("instance id", &id)?;
        if cpu.is_none() && memory_mb.is_none() && storage_gb.is_none() {
            return Err(
                "nothing to resize — pass at least one of cpu, memory_mb, storage_gb".to_string(),
            );
        }
        if let Some(cpu) = &cpu {
            safe_query_value("cpu cores", cpu)?;
        }
        let client = ApiClient::new(&base, token);

        let before = read_instance(&client, &id)?;
        // The platform's ResizeGuard checks the state first. Only a
        // row that can actually enter the sequence gets the local
        // no-op/shrink pre-check; a sleeping/pending row gets the
        // server's actionable state refusal instead.
        if matches!(before["status"].as_str(), Some("running" | "stopped"))
            && let Some(refusal) =
                allocation_precheck(&before, cpu.as_deref(), memory_mb, storage_gb)
        {
            return Err(refusal);
        }
        let previous_allocation = allocation_of(&before);
        let mut steps = json!({"stop": "skipped", "resize": "pending", "start": "pending"});
        let mut last_row = before.clone();
        let mut stopped_by_us = false;

        if before["status"] == "running" {
            match lifecycle_maybe(&client, &id, "stop") {
                Ok(row) if row["status"] == "stopped" => {
                    steps["stop"] = json!("done");
                    last_row = row;
                    stopped_by_us = true;
                }
                Ok(row) => {
                    last_row = row.clone();
                    return Ok(stop_failed(
                        &client,
                        &id,
                        steps,
                        &mut last_row,
                        format!(
                            "stop landed {} — the resize did not run",
                            row["status"].as_str().unwrap_or("an unknown state")
                        ),
                        previous_allocation,
                        true,
                    ));
                }
                Err((may_have_landed, message)) => {
                    return Ok(stop_failed(
                        &client,
                        &id,
                        steps,
                        &mut last_row,
                        message,
                        previous_allocation,
                        may_have_landed,
                    ));
                }
            }
        }

        let mut attrs = json!({});
        if let Some(cpu) = &cpu {
            attrs["cpu_cores"] = json!(cpu);
        }
        if let Some(memory_mb) = memory_mb {
            attrs["memory_mb"] = json!(memory_mb);
        }
        if let Some(storage_gb) = storage_gb {
            attrs["storage_gb"] = json!(storage_gb);
        }
        let body = json!({"data": {"type": "instance", "id": id, "attributes": attrs}});

        let resized = match client.send(
            "PATCH",
            &format!("/instances/{id}/resize"),
            Some(body.to_string()),
        ) {
            Ok(document) => match one_resource(document, "instance") {
                Ok(resource) => with_id(&resource),
                Err(message) => {
                    steps["resize"] = json!("failed");
                    return Ok(resize_failed(
                        &client,
                        &id,
                        &mut steps,
                        &mut last_row,
                        message,
                        previous_allocation,
                        stopped_by_us,
                    ));
                }
            },
            Err(err) => {
                steps["resize"] = json!("failed");
                return Ok(resize_failed(
                    &client,
                    &id,
                    &mut steps,
                    &mut last_row,
                    friendly_404(err, "instance"),
                    previous_allocation,
                    stopped_by_us,
                ));
            }
        };
        steps["resize"] = json!("done");
        last_row = resized.clone();

        let new_allocation = allocation_of(&resized);
        // Start before quoting: the instance comes back first, and a
        // slow pricing endpoint must not extend a stopped window.
        let start = lifecycle(&client, &id, "start");
        let price = price_for(&client, &new_allocation);

        match start {
            Ok(row) if row["status"] == "error" => {
                // A 200 whose landed state is :error is a failed start
                // (the action reports the row, not the cluster outcome).
                steps["start"] = json!("failed");
                last_row = row;
                let final_row = read_instance(&client, &id).unwrap_or(last_row);
                return Ok(json!({
                    "ok": false,
                    "step": "start",
                    "steps": steps,
                    "error": START_LANDED_ERROR,
                    "start_error": START_LANDED_ERROR,
                    "instance": final_row,
                    "previous_allocation": previous_allocation,
                    "new_allocation": new_allocation,
                    "price": price,
                    "price_currency": "USD",
                    "price_period": "monthly · billed hourly",
                    "price_basis": PRICE_BASIS,
                }));
            }
            Ok(row) => {
                steps["start"] = json!("done");
                last_row = row;
            }
            Err(message) => {
                // A start that failed after the scale may have landed
                // anyway (5xx/timeout): a row already starting/running
                // is the outcome the sequence wanted.
                let after = read_instance(&client, &id).unwrap_or_else(|_| last_row.clone());
                if matches!(after["status"].as_str(), Some("starting" | "running")) {
                    steps["start"] = json!("skipped");
                    last_row = after;
                } else {
                    steps["start"] = json!("failed");
                    let final_row = read_instance(&client, &id).unwrap_or(last_row);
                    return Ok(json!({
                        "ok": false,
                        "step": "start",
                        "steps": steps,
                        "error": message,
                        "start_error": message,
                        "instance": final_row,
                        "previous_allocation": previous_allocation,
                        "new_allocation": new_allocation,
                        "price": price,
                        "price_currency": "USD",
                        "price_period": "monthly · billed hourly",
                        "price_basis": PRICE_BASIS,
                    }));
                }
            }
        }

        // The actual state is the read-back, not the start call's row.
        let final_row = read_instance(&client, &id).unwrap_or(last_row);
        Ok(json!({
            "ok": true,
            "step": "start",
            "steps": steps,
            "error": Value::Null,
            "start_error": Value::Null,
            "started": true,
            "instance": final_row,
            "previous_allocation": previous_allocation,
            "new_allocation": new_allocation,
            "price": price,
            "price_currency": "USD",
            "price_period": "monthly · billed hourly",
            "price_basis": PRICE_BASIS,
        }))
    })
    .await
}

/// The one line that keeps a formula quote from reading as the final
/// charge at a recommended-size allocation.
const PRICE_BASIS: &str = "the platform's formula quote for this allocation; \
an allocation at the app version's recommended size bills that size's live rate instead";

/// A start call that answered 200 but landed `:error` (the action
/// reports the row, not the cluster outcome) — a failed start, never
/// a silent success.
const START_LANDED_ERROR: &str = "start landed error — the instance needs attention";

/// A stop-leg failure: no resize runs. A 5xx/transport error can follow
/// a committed scale, so when the error may have landed and the row is
/// now stopped, this call did stop it — restart and report both
/// outcomes. A definite 4xx refusal (or a row that is not stopped)
/// leaves `start` not attempted. Every wire is terminal on this
/// response (`resize`/`start` are `not_attempted`, never `pending`).
fn stop_failed(
    client: &ApiClient,
    id: &str,
    mut steps: Value,
    last_row: &mut Value,
    error: String,
    previous_allocation: Value,
    may_have_landed: bool,
) -> Value {
    let before = read_instance(client, id).unwrap_or_else(|_| last_row.clone());
    steps["resize"] = json!("not_attempted");

    let (start_error, started, error) = if may_have_landed && before["status"] == "stopped" {
        steps["stop"] = json!("done");
        match lifecycle(client, id, "start") {
            Ok(row) if row["status"] == "error" => {
                steps["start"] = json!("failed");
                *last_row = row;
                (
                    json!(START_LANDED_ERROR),
                    false,
                    format!("{error}; the restart landed error"),
                )
            }
            Ok(row) => {
                steps["start"] = json!("done");
                *last_row = row;
                (
                    Value::Null,
                    true,
                    format!("{error}; the instance was restarted"),
                )
            }
            Err(message) => {
                // A restart that failed after the scale may have
                // landed anyway (5xx/timeout): a row already
                // starting/running is up, not a failure.
                let after = read_instance(client, id).unwrap_or_else(|_| last_row.clone());
                if matches!(after["status"].as_str(), Some("starting" | "running")) {
                    steps["start"] = json!("skipped");
                    *last_row = after;
                    (
                        Value::Null,
                        true,
                        format!("{error}; the instance is running"),
                    )
                } else {
                    steps["start"] = json!("failed");
                    (
                        json!(message),
                        false,
                        format!("{error}; the restart failed"),
                    )
                }
            }
        }
    } else {
        steps["stop"] = json!("failed");
        steps["start"] = json!("not_attempted");
        (Value::Null, false, error)
    };

    let final_row = read_instance(client, id).unwrap_or_else(|_| last_row.clone());
    json!({
        "ok": false,
        "step": "stop",
        "steps": steps,
        "error": error,
        "start_error": start_error,
        "started": started,
        "instance": final_row,
        "previous_allocation": previous_allocation,
        "new_allocation": Value::Null,
        "price": Value::Null,
        "price_currency": "USD",
        "price_period": "monthly · billed hourly",
        "price_basis": PRICE_BASIS,
    })
}

/// A resize-leg failure: when this call stopped the instance, attempt
/// the start and report both outcomes plus the actual state. A row
/// this call never stopped (a sleeping/pending refusal, or a row that
/// was already stopped) is left exactly as it was — waking it would be
/// an unasked-for change. A racing start wins: a row already
/// starting/running is reported as such, never started again.
fn resize_failed(
    client: &ApiClient,
    id: &str,
    steps: &mut Value,
    last_row: &mut Value,
    error: String,
    previous_allocation: Value,
    stopped_by_us: bool,
) -> Value {
    let (start_error, started) = if !stopped_by_us {
        steps["start"] = json!("not_attempted");
        (Value::Null, false)
    } else {
        match lifecycle(client, id, "start") {
            Ok(row) if row["status"] == "error" => {
                steps["start"] = json!("failed");
                *last_row = row;
                (json!(START_LANDED_ERROR), false)
            }
            Ok(row) => {
                steps["start"] = json!("done");
                *last_row = row;
                (Value::Null, true)
            }
            Err(message) => {
                // A concurrent start can make ours 400 on the
                // platform's state guard; a row already
                // starting/running is the outcome the sequence
                // wanted, not a failure.
                let after = read_instance(client, id).unwrap_or_else(|_| last_row.clone());
                if matches!(after["status"].as_str(), Some("starting" | "running")) {
                    steps["start"] = json!("skipped");
                    *last_row = after;
                    (Value::Null, true)
                } else {
                    steps["start"] = json!("failed");
                    (json!(message), false)
                }
            }
        }
    };
    let final_row = read_instance(client, id).unwrap_or_else(|_| last_row.clone());
    json!({
        "ok": false,
        "step": "resize",
        "steps": steps,
        "error": error,
        "start_error": start_error,
        "started": started,
        "instance": final_row,
        "previous_allocation": previous_allocation,
        "new_allocation": Value::Null,
        "price": Value::Null,
        "price_currency": "USD",
        "price_period": "monthly · billed hourly",
        "price_basis": PRICE_BASIS,
    })
}

/// GET /instances/{id} as the flat row (the resize's state reads).
fn read_instance(client: &ApiClient, id: &str) -> Result<Value, String> {
    let document = client
        .get(&format!("/instances/{id}"))
        .map_err(|err| friendly_404(err, "instance"))?;
    one_resource(document, "instance").map(|resource| with_id(&resource))
}

/// The allocation triple off a flat instance row.
fn allocation_of(row: &Value) -> Value {
    json!({
        "cpu_cores": row.get("cpu_cores").cloned().unwrap_or(Value::Null),
        "memory_mb": row.get("memory_mb").cloned().unwrap_or(Value::Null),
        "storage_gb": row.get("storage_gb").cloned().unwrap_or(Value::Null),
    })
}

/// The two refusals the platform's ResizeGuard decides entirely from
/// the row the tool already read — a no-op allocation and a storage
/// shrink. Refusing here keeps a doomed resize from stopping a serving
/// instance first; the line mirrors the platform's `400 Invalid: …`
/// shape, and the caller sees the same detail either way. Anything the
/// row cannot answer (a missing dimension, a non-numeric current cpu)
/// is left to the server. Callers gate this on the resize-able states,
/// because the platform checks state first.
fn allocation_precheck(
    before: &Value,
    cpu: Option<&str>,
    memory_mb: Option<i64>,
    storage_gb: Option<i64>,
) -> Option<String> {
    let cpu_same = match cpu {
        None => true,
        Some(requested) => {
            let current = before["cpu_cores"].as_str();
            match (
                current.and_then(|value| value.parse::<f64>().ok()),
                requested.parse::<f64>().ok(),
            ) {
                (Some(current), Some(requested)) => current == requested,
                _ => false,
            }
        }
    };
    let memory_same = match memory_mb {
        None => true,
        Some(requested) => before["memory_mb"].as_i64() == Some(requested),
    };
    let storage_same = match storage_gb {
        None => true,
        Some(requested) => before["storage_gb"].as_i64() == Some(requested),
    };

    if cpu_same && memory_same && storage_same {
        return Some("400 Invalid: allocation is unchanged".to_string());
    }

    match (storage_gb, before["storage_gb"].as_i64()) {
        (Some(requested), Some(current)) if requested < current => Some(format!(
            "400 Invalid: storage can never shrink (from {current} GB to {requested} GB)"
        )),
        _ => None,
    }
}

/// The platform's quote for an allocation. Best-effort: the resize
/// already committed, so a pricing outage reports the row and the
/// price error instead of hiding the resize behind a failure.
fn price_for(client: &ApiClient, allocation: &Value) -> Value {
    let cpu = allocation["cpu_cores"]
        .as_str()
        .map(str::to_owned)
        .or_else(|| allocation["cpu_cores"].as_f64().map(|n| n.to_string()));
    let memory_mb = allocation["memory_mb"].as_i64();
    let storage_gb = allocation["storage_gb"].as_i64();

    let (Some(cpu), Some(memory_mb), Some(storage_gb)) = (cpu, memory_mb, storage_gb) else {
        return json!({"error": "the resize response did not carry a complete allocation"});
    };
    if safe_query_value("cpu cores", &cpu).is_err() {
        return json!({"error": format!("invalid cpu cores in the resize response: {cpu}")});
    }

    match client.get_json(&format!(
        "/pricing/quote?cpu_cores={cpu}&memory_mb={memory_mb}&storage_gb={storage_gb}"
    )) {
        Ok(quote) => quote,
        Err(err) => json!({"error": message(err)}),
    }
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
/// (fenced as a QUERY value — `&`/`#`/whitespace would reshape the
/// request; `%` escapes ride untouched, and path-segment rules like
/// `/` don't apply); `next_cursor` rides the answer while a next page
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
            safe_query_value("ledger cursor", cursor)?;
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

/// The org-scoped top-up page (#770): the org wallet funds the org's
/// instances (ADR-0042 Option A), so the onboarding `fund` step links
/// that org's wizard — the personal route is only right for the
/// personal org.
fn funding_url(base: &str, org: &OrganizationRow) -> Option<String> {
    org.slug.as_deref().map(|slug| {
        format!(
            "{}/organizations/{slug}/billing/topup",
            base.trim_end_matches('/')
        )
    })
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

/// One URL QUERY value (the ledger cursor): `&` would inject another
/// parameter, `#` would cut the fragment, whitespace never rides a
/// request line — those are refused up front. Everything else passes
/// VERBATIM: real cursors are base64url, and `%` escapes (a `%2B`
/// inside one) are already-encoded query bytes the platform decodes —
/// re-encoding or refusing them would corrupt the keyset position.
/// Path-segment rules (`/`, `..`) don't apply to a query value.
fn safe_query_value(thing: &str, value: &str) -> Result<(), String> {
    let bad =
        value.is_empty() || value.contains(['&', '#']) || value.chars().any(char::is_whitespace);
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

    // ---- #770: org resolution, the quote, org creation, onboarding

    fn two_orgs_doc() -> String {
        envelope(json!({"data": [
            {"type": "organization", "id": "01JORG1",
             "attributes": {"slug": "personal", "name": "Personal"}},
            {"type": "organization", "id": "01JORG2",
             "attributes": {"slug": "acme", "name": "Acme"}}
        ]}))
    }

    #[tokio::test]
    async fn resolve_organization_takes_the_sole_org_or_refuses_listing_the_choices() {
        // Sole: the fallback.
        let sole = serve(&[("/api/v1/organizations", 200, &envelope(orgs_doc()))]);
        let org = resolve_organization(&ApiClient::new(&sole.base_url, token()), None).unwrap();
        assert_eq!(org.id, "01JORG1");

        // Several, unnamed: refuse WITH the choices — never a pick.
        let two = serve(&[("/api/v1/organizations", 200, &two_orgs_doc())]);
        let err = resolve_organization(&ApiClient::new(&two.base_url, token()), None).unwrap_err();
        assert!(err.contains("multiple organizations"), "err: {err}");
        assert!(err.contains("Personal (personal)"), "err: {err}");
        assert!(err.contains("Acme (acme)"), "err: {err}");

        // None: the honest no-org line points at the creation tool.
        let none = serve(&[("/api/v1/organizations", 200, &envelope(json!({"data": []})))]);
        let err = resolve_organization(&ApiClient::new(&none.base_url, token()), None).unwrap_err();
        assert!(err.contains("no organization to deploy into"), "err: {err}");
        assert!(err.contains("organizations_create"), "err: {err}");

        // An explicit slug or id wins; an unknown name refuses.
        let two = serve(&[("/api/v1/organizations", 200, &two_orgs_doc())]);
        let client = ApiClient::new(&two.base_url, token());
        assert_eq!(
            resolve_organization(&client, Some("acme")).unwrap().id,
            "01JORG2"
        );
        assert_eq!(
            resolve_organization(&client, Some("01JORG1")).unwrap().id,
            "01JORG1"
        );
        let err = resolve_organization(&client, Some("ghost")).unwrap_err();
        assert!(
            err.contains("no organization with id or slug \"ghost\""),
            "err: {err}"
        );
        assert!(err.contains("Acme (acme)"), "err: {err}");
    }

    #[tokio::test]
    async fn pricing_quote_returns_the_platforms_cents() {
        let server = serve(&[(
            "/api/v1/pricing/quote?cpu_cores=0.5&memory_mb=512&storage_gb=10",
            200,
            r#"{"cpu_cores":"0.5","memory_mb":512,"storage_gb":10,
                "monthly_cents":335,"stopped_monthly_cents":40,
                "monthly":"$3.35/mo · billed hourly","stopped":"$0.40 while stopped"}"#,
        )]);
        let quote = pricing_quote(base(&server), token(), "0.5".into(), 512, 10)
            .await
            .unwrap();
        assert_eq!(quote["monthly_cents"], 335);
        assert_eq!(quote["stopped_monthly_cents"], 40);
        let head = server.head(0).to_lowercase();
        assert!(
            head.starts_with("get /api/v1/pricing/quote?cpu_cores=0.5&memory_mb=512&storage_gb=10"),
            "head: {head}"
        );
    }

    #[tokio::test]
    async fn pricing_quote_refuses_a_query_shaping_cpu_without_a_wire_call() {
        let dead: Arc<str> = Arc::from("http://127.0.0.1:1");
        for cpu in ["0.5&storage_gb=1", "0.5#x", "a b", ""] {
            let err = pricing_quote(dead.clone(), token(), cpu.into(), 512, 10)
                .await
                .unwrap_err();
            assert_eq!(err, format!("invalid cpu cores: {cpu}"));
        }
    }

    #[tokio::test]
    async fn organizations_create_posts_the_actor_path_body() {
        let server = script(vec![respond_envelope(
            "201 Created",
            json!({"data": {"type": "organization", "id": "01JORG9",
                            "attributes": {"slug": "team", "name": "Team"}}}),
        )]);
        let row = organizations_create(base_of(&server), token(), "Team".into(), "team".into())
            .await
            .unwrap();
        assert_eq!(row["id"], "01JORG9");
        assert_eq!(row["slug"], "team");
        let raw = server.requests.lock().unwrap()[0].clone();
        assert!(raw.starts_with("POST /api/v1/organizations"), "raw: {raw}");
        assert!(raw.contains("\"name\":\"Team\""), "raw: {raw}");
        assert!(raw.contains("\"slug\":\"team\""), "raw: {raw}");
    }

    #[tokio::test]
    async fn organizations_create_surfaces_the_reserved_slug_refusal_verbatim() {
        let server = script(vec![respond(
            "400 Bad Request",
            r#"{"errors":[{"status":"400","title":"InvalidAttribute","detail":"is reserved"}]}"#,
        )]);
        let err = organizations_create(base_of(&server), token(), "Docs".into(), "docs".into())
            .await
            .unwrap_err();
        assert_eq!(err, "400 InvalidAttribute: is reserved");
    }

    #[tokio::test]
    async fn instances_list_scopes_to_the_named_organization() {
        let org_instances = envelope(json!({"data": [
            {"type": "instance", "id": "i9",
             "attributes": {"id": "i9", "name": "org app", "status": "running"}}
        ]}));
        let server = serve(&[
            ("/api/v1/organizations", 200, &two_orgs_doc()),
            (
                "/api/v1/organizations/01JORG2/instances",
                200,
                &org_instances,
            ),
        ]);
        let row = instances_list(base(&server), token(), Some("acme".into()))
            .await
            .unwrap();
        assert_eq!(row["instances"][0]["id"], "i9");
        let heads: Vec<String> = (0..2).map(|n| server.head(n).to_lowercase()).collect();
        assert!(
            heads[0].starts_with("get /api/v1/organizations"),
            "{heads:?}"
        );
        assert!(
            heads[1].starts_with("get /api/v1/organizations/01jorg2/instances"),
            "{heads:?}"
        );
    }

    #[tokio::test]
    async fn instances_list_refuses_an_unknown_organization_listing_yours() {
        let server = serve(&[("/api/v1/organizations", 200, &two_orgs_doc())]);
        let err = instances_list(base(&server), token(), Some("ghost".into()))
            .await
            .unwrap_err();
        assert!(
            err.contains("no organization with id or slug \"ghost\""),
            "err: {err}"
        );
        assert_eq!(server.head_count(), 1);
    }

    #[tokio::test]
    async fn onboarding_status_fresh_account_reads_deploy() {
        let wallet = envelope(json!({"data": {"type": "wallet", "id": "w1",
            "attributes": {"id": "w1", "organization_id": "01JORG1",
                           "balance": 300, "paywall_waived": false}}}));
        let server = serve(&[
            ("/api/v1/me", 200, &envelope(me_doc())),
            ("/api/v1/organizations", 200, &envelope(orgs_doc())),
            ("/api/v1/organizations/01JORG1/wallet", 200, &wallet),
            (
                "/api/v1/organizations/01JORG1/wallet/runway",
                200,
                r#"{"balance_cents":300,"burn_micro_cents_per_hour":0,"runway_hours":"infinity"}"#,
            ),
            (
                "/api/v1/organizations/01JORG1/instances",
                200,
                &envelope(json!({"data": []})),
            ),
        ]);
        let status = onboarding_status(base(&server), token(), None)
            .await
            .unwrap();
        assert_eq!(status["account"]["email"], "me@example.com");
        assert_eq!(status["account"]["verified"], true);
        assert_eq!(status["organizations"][0]["slug"], "personal");
        assert_eq!(status["organization"]["id"], "01JORG1");
        assert_eq!(status["wallet"]["balance_cents"], 300);
        assert_eq!(status["wallet"]["runway_hours"], "infinity");
        assert_eq!(status["instance_count"], 0);
        assert_eq!(status["next_step"], "deploy");
        assert_eq!(
            status["funding_url"].as_str().unwrap(),
            format!("{}/organizations/personal/billing/topup", base(&server))
        );
        // The composed reads, in order: me, orgs, wallet, runway, instances.
        assert_eq!(server.head_count(), 5);
    }

    #[tokio::test]
    async fn onboarding_status_chooses_fund_and_connect_domain() {
        // Several orgs, none named: choose_org (no wallet read).
        let server = serve(&[
            ("/api/v1/me", 200, &envelope(me_doc())),
            ("/api/v1/organizations", 200, &two_orgs_doc()),
            ("/api/v1/instances", 200, &envelope(json!({"data": []}))),
        ]);
        let status = onboarding_status(base(&server), token(), None)
            .await
            .unwrap();
        assert_eq!(status["organization"], Value::Null);
        assert_eq!(status["next_step"], "choose_org");
        assert_eq!(status["funding_url"], Value::Null);

        // A chosen org without a wallet row (team org, lazily billed):
        // fund, balance 0.
        let server = serve(&[
            ("/api/v1/me", 200, &envelope(me_doc())),
            ("/api/v1/organizations", 200, &two_orgs_doc()),
            (
                "/api/v1/organizations/01JORG2/instances",
                200,
                &envelope(json!({"data": []})),
            ),
        ]);
        let status = onboarding_status(base(&server), token(), Some("acme".into()))
            .await
            .unwrap();
        assert_eq!(status["organization"]["slug"], "acme");
        assert_eq!(status["wallet"], Value::Null);
        assert_eq!(status["next_step"], "fund");
        assert_eq!(
            status["funding_url"].as_str().unwrap(),
            format!("{}/organizations/acme/billing/topup", base(&server))
        );

        // Funded with an instance: the last onboarding step.
        let wallet = envelope(json!({"data": {"type": "wallet", "id": "w1",
            "attributes": {"id": "w1", "organization_id": "01JORG1",
                           "balance": 900, "paywall_waived": false}}}));
        let server = serve(&[
            ("/api/v1/me", 200, &envelope(me_doc())),
            ("/api/v1/organizations", 200, &envelope(orgs_doc())),
            ("/api/v1/organizations/01JORG1/wallet", 200, &wallet),
            (
                "/api/v1/organizations/01JORG1/wallet/runway",
                200,
                r#"{"balance_cents":900,"burn_micro_cents_per_hour":1,"runway_hours":900.0}"#,
            ),
            (
                "/api/v1/organizations/01JORG1/instances",
                200,
                &envelope(json!({"data": [
                    {"type": "instance", "id": "i1", "attributes": {"id": "i1"}}
                ]})),
            ),
        ]);
        let status = onboarding_status(base(&server), token(), None)
            .await
            .unwrap();
        assert_eq!(status["instance_count"], 1);
        assert_eq!(status["next_step"], "connect_domain");
    }

    #[tokio::test]
    async fn onboarding_status_refuses_an_unknown_named_organization() {
        let server = serve(&[
            ("/api/v1/me", 200, &envelope(me_doc())),
            ("/api/v1/organizations", 200, &envelope(orgs_doc())),
        ]);
        let err = onboarding_status(base(&server), token(), Some("ghost".into()))
            .await
            .unwrap_err();
        assert!(
            err.contains("no organization with id or slug \"ghost\""),
            "err: {err}"
        );
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
    async fn apps_show_returns_the_manual_from_the_newest_version() {
        let body = &envelope(json!({"data": {
            "type": "app", "id": "1", "attributes": {"name": "WordPress", "slug": "wordpress"}
        }}));
        // Newest first; the newest row carries the whole deploy
        // contract (#770) and the platform's monthly_cents (#765).
        // The older row is there to prove the read takes only the first.
        let versions = envelope(json!({"data": [
            {"type": "app_version", "id": "v2", "attributes": {
                "version": "1.2",
                "monthly_cents": 335,
                "default_cpu_cores": "0.5",
                "default_memory_mb": 512,
                "default_storage_gb": 10,
                "configurable_env_vars": {"WP_SITE_URL": {
                    "label": "Site URL", "description": "The public address.",
                    "type": "string", "required": false, "secret": false,
                    "default": "https://example.test"
                }},
                "first_run": {"pattern": "first_registered_user_admin",
                              "env": {"INSTALL_LOCK": "true"},
                              "forbidden_env": ["DISABLE_REGISTRATION"],
                              "guidance": "Open the instance and register."},
                "backing_services": [{"kind": "postgres", "version": "18",
                                      "url_env": "DATABASE_URL"}],
                "oidc_wiring": {"kind": "env", "issuer_env": "OIDC_ISSUER",
                                "client_id_env": "OIDC_CLIENT_ID",
                                "client_secret_env": "OIDC_CLIENT_SECRET",
                                "pkce": true}
            }},
            {"type": "app_version", "id": "v1", "attributes": {"version": "1.0"}}
        ]}));
        let quote = r#"{"cpu_cores":"0.5","memory_mb":512,"storage_gb":10,
            "monthly_cents":335,"stopped_monthly_cents":40,
            "monthly":"$3.35/mo · billed hourly","stopped":"$0.40 while stopped"}"#;
        let server = serve(&[
            ("/api/v1/apps/wordpress", 200, body),
            ("/api/v1/apps/1/versions", 200, &versions),
            ("/api/v1/app-versions/v2/quote", 200, quote),
        ]);
        let row = apps_show(base(&server), token(), "wordpress".into())
            .await
            .unwrap();
        assert_eq!(row["id"], "1");
        assert_eq!(row["name"], "WordPress");
        assert_eq!(row["versions"][0]["id"], "v2");
        assert_eq!(row["versions"][0]["monthly_cents"], 335);
        let head = server.head(0).to_lowercase();
        assert!(
            head.starts_with("get /api/v1/apps/wordpress"),
            "head: {head}"
        );
        let versions_head = server.head(1).to_lowercase();
        assert!(
            versions_head.starts_with("get /api/v1/apps/1/versions"),
            "head: {versions_head}"
        );

        let version = &row["version"];
        assert_eq!(version["id"], "v2");
        assert_eq!(version["default_cpu_cores"], "0.5");
        assert_eq!(version["default_memory_mb"], 512);
        assert_eq!(version["default_storage_gb"], 10);
        assert_eq!(
            version["configurable_env_vars"]["WP_SITE_URL"]["default"],
            "https://example.test"
        );
        assert_eq!(
            version["first_run"]["pattern"],
            "first_registered_user_admin"
        );
        assert_eq!(version["first_run"]["env"]["INSTALL_LOCK"], "true");
        assert_eq!(version["backing_services"][0]["url_env"], "DATABASE_URL");
        assert_eq!(version["oidc_wiring"]["issuer_env"], "OIDC_ISSUER");
        assert_eq!(
            version["oidc_wiring"]["client_secret_env"],
            "OIDC_CLIENT_SECRET"
        );

        // The quote is the PLATFORM's cents, shipped as-is.
        assert_eq!(version["pricing"]["monthly_cents"], 335);
        assert_eq!(version["pricing"]["stopped_monthly_cents"], 40);
        assert_eq!(version["pricing"]["monthly"], "$3.35/mo · billed hourly");

        // No always-shipped values ride (default_env_vars is the
        // operator-owned half), and the three reads are the sequence.
        assert!(version.get("default_env_vars").is_none());
        assert_eq!(server.head_count(), 3);
    }

    #[tokio::test]
    async fn apps_show_without_a_version_answers_a_null_manual() {
        let body = &envelope(json!({"data": {
            "type": "app", "id": "1", "attributes": {"name": "New", "slug": "new"}
        }}));
        let server = serve(&[
            ("/api/v1/apps/new", 200, body),
            (
                "/api/v1/apps/1/versions",
                200,
                &envelope(json!({"data": []})),
            ),
        ]);

        let row = apps_show(base(&server), token(), "new".into())
            .await
            .unwrap();
        assert_eq!(row["version"], serde_json::Value::Null);
        // Two reads — no quote for a sizeless version.
        assert_eq!(server.head_count(), 2);
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
        let wrapped = instances_list(base(&list), token(), None).await.unwrap();
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
    async fn me_grant_carries_the_resource_audience() {
        let server = serve(&[(
            "/api/v1/me",
            200,
            &envelope(json!({
                "data": {"type": "user", "id": "u1", "attributes": {}},
                "meta": {
                    "scopes": ["instances:read"],
                    "resource": "https://mcp.fluxvale.com/mcp"
                }
            })),
        )]);
        let grant = me_grant(base(&server), token()).await.unwrap();
        assert_eq!(grant.scopes, ["instances:read"]);
        assert_eq!(
            grant.resource.as_deref(),
            Some("https://mcp.fluxvale.com/mcp")
        );
    }

    #[tokio::test]
    async fn me_grant_without_a_resource_is_a_pat_or_a_pre_766_answer() {
        let server = serve(&[("/api/v1/me", 200, &me_doc_with_scopes(&["instances:read"]))]);
        let grant = me_grant(base(&server), token()).await.unwrap();
        assert!(grant.resource.is_none());
    }

    #[tokio::test]
    async fn a_zero_scope_token_answers_the_empty_list() {
        // A minted "no grants" fact, not an omission (#585's contract).
        let server = serve(&[("/api/v1/me", 200, &me_doc_with_scopes(&[]))]);
        let scopes = me_scopes(base(&server), token()).await.unwrap();
        assert!(scopes.is_empty());
    }

    #[tokio::test]
    async fn a_me_without_meta_scopes_is_the_shape_error_with_its_own_line() {
        // A session-shaped /me answer (no meta) is not a token
        // caller's answer — never a silent "no tools" (nor "all"),
        // and never worded as a transient outage.
        let server = serve(&[("/api/v1/me", 200, &envelope(me_doc()))]);
        let err = me_scopes(base(&server), token()).await.unwrap_err();
        assert!(matches!(err, ScopeError::Shape(_)), "got: {err:?}");
        assert!(
            err_message(&err).contains("not a PAT caller, or the platform predates #585"),
            "message: {}",
            err_message(&err)
        );
        // A non-string scope entry is the same shape surprise.
        let body = envelope(json!({
            "data": me_doc()["data"].clone(),
            "meta": {"scopes": [7]}
        }));
        let server = serve(&[("/api/v1/me", 200, &body)]);
        let err = me_scopes(base(&server), token()).await.unwrap_err();
        assert!(matches!(err, ScopeError::Shape(_)));
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
            ScopeError::Auth(message)
            | ScopeError::Shape(message)
            | ScopeError::Upstream(message) => message.clone(),
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
            name: "my forgejo".into(),
            cpu: None,
            memory_mb: None,
            storage_gb: None,
            version: None,
            env: None,
            organization: None,
        }
    }

    fn orgs_row() -> serde_json::Value {
        json!({"data": [
            {"type": "organization", "id": "org1",
             "attributes": {"slug": "personal", "name": "Personal"}}
        ]})
    }

    fn deploy_responses() -> Vec<String> {
        vec![
            // #770: the org resolves first — the sole-org fallback
            // (the provider's rule).
            respond_envelope("200 OK", orgs_row()),
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
        assert_eq!(requests.len(), 5, "orgs, app, versions, create, deploy");
        assert!(
            requests[0].starts_with("get /api/v1/organizations http/1.1"),
            "req0: {}",
            requests[0]
        );
        assert!(
            requests[1].starts_with("get /api/v1/apps/forgejo http/1.1"),
            "req1: {}",
            requests[1]
        );
        assert!(
            requests[2].starts_with("get /api/v1/apps/app1/versions http/1.1"),
            "req2: {}",
            requests[2]
        );
        assert!(
            requests[3].starts_with("post /api/v1/instances http/1.1"),
            "req3: {}",
            requests[3]
        );
        assert!(
            requests[4].starts_with("patch /api/v1/instances/i1/deploy http/1.1"),
            "req4: {}",
            requests[4]
        );
        // The create body: the NEWEST version (the wire's own order),
        // the name (always — the wire requires it), the resolved sole
        // org, no env_vars and no unset resource flags.
        assert!(
            requests[3].contains("\"app_version_id\":\"v2\""),
            "req3: {}",
            requests[3]
        );
        assert!(
            requests[3].contains("\"name\":\"my forgejo\""),
            "req3: {}",
            requests[3]
        );
        assert!(
            requests[3].contains("\"organization_id\":\"org1\""),
            "req3: {}",
            requests[3]
        );
        assert!(!requests[3].contains("env_vars"), "req3: {}", requests[3]);
        assert!(
            !requests[3].contains("cpu_cores"),
            "unset flags stay out: {}",
            requests[3]
        );
    }

    #[tokio::test]
    async fn deploy_carries_only_the_given_resource_flags() {
        let server = script(deploy_responses());
        let flags = DeployWire {
            cpu: Some("1.5".into()),
            memory_mb: Some(1024),
            storage_gb: Some(5),
            ..deploy_wire()
        };
        instances_deploy(base_of(&server), token(), flags)
            .await
            .unwrap();
        let create = &captured_requests(&server)[3];
        assert!(create.contains("\"cpu_cores\":\"1.5\""), "create: {create}");
        assert!(create.contains("\"memory_mb\":1024"), "create: {create}");
        assert!(create.contains("\"storage_gb\":5"), "create: {create}");
        // The name rides even alongside resource flags — required.
        assert!(
            create.contains("\"name\":\"my forgejo\""),
            "create: {create}"
        );
    }

    #[tokio::test]
    async fn deploy_carries_env_vars_on_the_create() {
        let server = script(deploy_responses());
        let flags = DeployWire {
            env: Some(std::collections::BTreeMap::from([
                ("API_KEY".to_string(), "sekrit".to_string()),
                ("TZ".to_string(), "UTC".to_string()),
            ])),
            ..deploy_wire()
        };
        instances_deploy(base_of(&server), token(), flags)
            .await
            .unwrap();
        let create = &captured_requests(&server)[3];
        assert!(
            create.contains("\"env_vars\":{\"api_key\":\"sekrit\",\"tz\":\"utc\"}"),
            "create: {create}"
        );
        // captured_requests lowercases; env names are case-sensitive,
        // so pin the RAW capture too.
        let raw = server.requests.lock().unwrap();
        assert!(
            raw[3].contains("\"env_vars\":{\"API_KEY\":\"sekrit\",\"TZ\":\"UTC\"}"),
            "raw create: {}",
            raw[3]
        );
    }

    #[tokio::test]
    async fn configure_patches_set_and_remove_and_never_echoes_values() {
        let updated = json!({"data": {"type": "instance", "id": "i1", "attributes": {"id": "i1", "status": "running"}}});
        let server = script(vec![respond_envelope("200 OK", updated)]);
        let row = instances_configure(
            base_of(&server),
            token(),
            "i1".into(),
            Some(std::collections::BTreeMap::from([(
                "API_KEY".to_string(),
                "sekrit".to_string(),
            )])),
            Some(vec!["OLD".to_string()]),
        )
        .await
        .unwrap();
        assert_eq!(row["status"], "running");
        assert!(!row.to_string().contains("sekrit"));

        let requests = captured_requests(&server);
        assert_eq!(requests.len(), 1);
        assert!(
            requests[0].starts_with("patch /api/v1/instances/i1/env http/1.1"),
            "req0: {}",
            requests[0]
        );
        assert!(
            requests[0]
                .contains("{\"data\":{\"attributes\":{\"remove\":[\"old\"],\"set\":{\"api_key\":\"sekrit\"}},\"id\":\"i1\",\"type\":\"instance\"}}"),
            "req0: {}",
            requests[0]
        );
    }

    #[tokio::test]
    async fn configure_refuses_an_empty_patch_before_any_request() {
        let server = script(vec![]);
        let err = instances_configure(base_of(&server), token(), "i1".into(), None, Some(vec![]))
            .await
            .unwrap_err();
        assert_eq!(
            err,
            "nothing to change — pass at least one env key to set or remove"
        );
        assert_eq!(captured_requests(&server).len(), 0);
    }

    #[tokio::test]
    async fn configure_refuses_a_route_hijacking_id() {
        let err = instances_configure(
            Arc::from("http://127.0.0.1:1"),
            token(),
            "a/b".into(),
            Some(std::collections::BTreeMap::from([(
                "K".to_string(),
                "v".to_string(),
            )])),
            None,
        )
        .await
        .unwrap_err();
        assert_eq!(err, "invalid instance id: a/b");
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
        let create = &captured_requests(&server)[3];
        assert!(
            create.contains("\"app_version_id\":\"v1\""),
            "create: {create}"
        );
    }

    #[tokio::test]
    async fn deploy_carries_the_named_organization_and_refuses_ambiguity() {
        // Explicit slug: the create body names that org.
        let server = script({
            let mut responses = deploy_responses();
            // Swap the sole-org answer for two orgs.
            responses[0] = respond_envelope(
                "200 OK",
                json!({"data": [
                    {"type": "organization", "id": "01JORG1",
                     "attributes": {"slug": "personal", "name": "Personal"}},
                    {"type": "organization", "id": "01JORG2",
                     "attributes": {"slug": "acme", "name": "Acme"}}
                ]}),
            );
            responses
        });
        let flags = DeployWire {
            organization: Some("acme".into()),
            ..deploy_wire()
        };
        instances_deploy(base_of(&server), token(), flags)
            .await
            .unwrap();
        let create = &captured_requests(&server)[3];
        assert!(
            create.contains("\"organization_id\":\"01jorg2\""),
            "create: {create}"
        );

        // Two orgs, no name: refuse before any app read.
        let server = script(vec![respond_envelope(
            "200 OK",
            json!({"data": [
                {"type": "organization", "id": "01JORG1",
                 "attributes": {"slug": "personal", "name": "Personal"}},
                {"type": "organization", "id": "01JORG2",
                 "attributes": {"slug": "acme", "name": "Acme"}}
            ]}),
        )]);
        let err = instances_deploy(base_of(&server), token(), deploy_wire())
            .await
            .unwrap_err();
        assert!(err.contains("multiple organizations"), "err: {err}");
        assert_eq!(captured_requests(&server).len(), 1);
    }

    #[tokio::test]
    async fn deploy_refusals_surface_their_own_words() {
        // Unknown app: the CLI's friendly 404 line, nothing else sent
        // past the org resolve.
        let server = script(vec![respond_envelope("200 OK", orgs_row()), not_found()]);
        let err = instances_deploy(base_of(&server), token(), deploy_wire())
            .await
            .unwrap_err();
        assert_eq!(err, "no such app (or it's not yours)");
        assert_eq!(captured_requests(&server).len(), 2);

        // No published versions.
        let server = script(vec![
            respond_envelope("200 OK", orgs_row()),
            respond_envelope("200 OK", json!({"data": app_row("forgejo", "app1")})),
            respond_envelope("200 OK", json!({"data": []})),
        ]);
        let err = instances_deploy(base_of(&server), token(), deploy_wire())
            .await
            .unwrap_err();
        assert_eq!(err, "forgejo has no published versions");

        // A foreign version id: the refusal lists the app's own.
        let server = script(vec![
            respond_envelope("200 OK", orgs_row()),
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
            respond_envelope("200 OK", orgs_row()),
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
    async fn configure_patch_carries_retention_and_enabled_together() {
        // The silent-re-enable regression guard: a PATCH that sets
        // retention must still carry an explicit enabled:false —
        // absent keys leave the row's value alone, so dropping one
        // would quietly re-enable a paused row.
        let server = script(vec![
            respond_envelope("200 OK", json!({"data": setting_row()})),
            respond_envelope("200 OK", json!({"data": setting_row()})),
        ]);
        backups_configure(
            base_of(&server),
            token(),
            ConfigureBackupWire {
                retention_keep: Some(5),
                enabled: Some(false),
                ..configure_wire()
            },
        )
        .await
        .unwrap();
        let patch = &captured_requests(&server)[1];
        assert!(patch.contains("\"retention_keep\":5"), "patch: {patch}");
        assert!(patch.contains("\"enabled\":false"), "patch: {patch}");
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

        // A cursor with a percent escape rides VERBATIM — the %2B is
        // already-encoded query bytes (a real base64url cursor may
        // carry one); the fence refuses only query-reshaping values.
        let server = script(vec![
            respond_envelope("200 OK", json!({"data": wallet_row()})),
            respond_envelope("200 OK", json!({"data": [], "links": {}})),
        ]);
        let answer = wallet_ledger(
            base_of(&server),
            token(),
            "01JORG1".into(),
            Some("Y3Vyc29y%2B".into()),
            None,
        )
        .await
        .unwrap();
        assert!(answer.get("next_cursor").is_none(), "answer: {answer}");
        let requests = captured_requests(&server);
        assert!(
            requests[1].starts_with(
                "get /api/v1/wallets/w1/ledger-entries?page[limit]=25&sort=-id&page[after]=y3vyc29y%2b http/1.1"
            ),
            "req1: {}",
            requests[1]
        );

        // The fence: query-reshaping cursors refuse before any wire
        // call (& injects, # cuts, whitespace never rides a request
        // line, empty is no cursor at all).
        let dead: Arc<str> = Arc::from("http://127.0.0.1:1");
        assert_eq!(
            wallet_ledger(dead.clone(), token(), "o".into(), None, Some(0))
                .await
                .unwrap_err(),
            "invalid limit 0: must be at least 1"
        );
        for bad in ["a&limit=100", "a#x", "a b", ""] {
            assert_eq!(
                wallet_ledger(dead.clone(), token(), "o".into(), Some(bad.into()), None)
                    .await
                    .unwrap_err(),
                format!("invalid ledger cursor: {bad}")
            );
        }
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
    fn funding_url_is_org_scoped_and_needs_a_slug() {
        let org = OrganizationRow {
            id: "01JORG2".into(),
            slug: Some("acme".into()),
            name: None,
        };
        assert_eq!(
            funding_url("https://fluxvale.com", &org).as_deref(),
            Some("https://fluxvale.com/organizations/acme/billing/topup")
        );
        assert_eq!(
            funding_url("http://127.0.0.1:4000/", &org).as_deref(),
            Some("http://127.0.0.1:4000/organizations/acme/billing/topup")
        );
        let slugless = OrganizationRow {
            id: "01JORG3".into(),
            slug: None,
            name: Some("No slug".into()),
        };
        assert_eq!(funding_url("https://fluxvale.com", &slugless), None);
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

    fn instance_status_doc(status: &str) -> String {
        json!({"data": {"type": "instance", "id": "i1",
            "attributes": {"id": "i1", "status": status}}})
        .to_string()
    }

    #[test]
    fn stop_failed_restarts_a_row_the_stop_left_stopped() {
        let stopped = instance_status_doc("stopped");
        let starting = instance_status_doc("starting");
        let server = serve(&[
            ("/api/v1/instances/i1", 200, &stopped),
            ("PATCH /api/v1/instances/i1/start", 200, &starting),
        ]);
        let client = ApiClient::new(&base(&server), token());
        let mut last_row = json!({"status": "running"});
        let value = stop_failed(
            &client,
            "i1",
            json!({"stop": "failed", "resize": "pending", "start": "pending"}),
            &mut last_row,
            "stop timed out".to_string(),
            json!({"cpu_cores": "0.5"}),
            true,
        );
        assert_eq!(value["ok"], false);
        assert_eq!(value["step"], "stop");
        assert_eq!(value["steps"]["stop"], "done");
        assert_eq!(value["steps"]["resize"], "not_attempted");
        assert_eq!(value["steps"]["start"], "done");
        assert_eq!(value["started"], true);
        assert!(
            value["error"].as_str().unwrap().contains("restarted"),
            "error: {}",
            value["error"]
        );
        assert!(
            (0..server.head_count())
                .map(|n| server.head(n).to_lowercase())
                .any(|head| head.starts_with("patch /api/v1/instances/i1/start"))
        );
    }

    #[test]
    fn stop_failed_leaves_a_running_row_alone() {
        let running = instance_status_doc("running");
        let server = serve(&[("/api/v1/instances/i1", 200, &running)]);
        let client = ApiClient::new(&base(&server), token());
        let mut last_row = json!({"status": "running"});
        let value = stop_failed(
            &client,
            "i1",
            json!({"stop": "failed", "resize": "pending", "start": "pending"}),
            &mut last_row,
            "stop refused".to_string(),
            json!({}),
            false,
        );
        assert_eq!(value["steps"]["stop"], "failed");
        assert_eq!(value["steps"]["resize"], "not_attempted");
        assert_eq!(value["steps"]["start"], "not_attempted");
        assert_eq!(value["started"], false);
        assert!(
            (0..server.head_count())
                .map(|n| server.head(n).to_lowercase())
                .all(|head| !head.starts_with("patch /api/v1/instances/i1/start"))
        );
    }

    #[test]
    fn stop_failed_does_not_restart_a_row_a_refusal_did_not_stop() {
        // The row is stopped, but a definite 4xx proves our call did
        // not do it — starting it would undo someone else's pause.
        let stopped = instance_status_doc("stopped");
        let server = serve(&[("/api/v1/instances/i1", 200, &stopped)]);
        let client = ApiClient::new(&base(&server), token());
        let mut last_row = json!({"status": "stopped"});
        let value = stop_failed(
            &client,
            "i1",
            json!({"stop": "failed", "resize": "pending", "start": "pending"}),
            &mut last_row,
            "400 Invalid: cannot stop instance in stopped state".to_string(),
            json!({}),
            false,
        );
        assert_eq!(value["steps"]["stop"], "failed");
        assert_eq!(value["steps"]["start"], "not_attempted");
        assert_eq!(value["started"], false);
        assert_eq!(value["start_error"], Value::Null);
        assert!(
            (0..server.head_count())
                .map(|n| server.head(n).to_lowercase())
                .all(|head| !head.starts_with("patch /api/v1/instances/i1/start"))
        );
    }

    #[test]
    fn stop_failed_reports_a_restart_that_lands_error() {
        let stopped = instance_status_doc("stopped");
        let erred = instance_status_doc("error");
        let server = serve(&[
            ("/api/v1/instances/i1", 200, &stopped),
            ("PATCH /api/v1/instances/i1/start", 200, &erred),
        ]);
        let client = ApiClient::new(&base(&server), token());
        let mut last_row = json!({"status": "running"});
        let value = stop_failed(
            &client,
            "i1",
            json!({"stop": "failed", "resize": "pending", "start": "pending"}),
            &mut last_row,
            "stop timed out".to_string(),
            json!({}),
            true,
        );
        assert_eq!(value["steps"]["start"], "failed");
        assert_eq!(value["started"], false);
        assert_eq!(value["start_error"], START_LANDED_ERROR);
        assert!(
            value["error"]
                .as_str()
                .unwrap()
                .contains("restart landed error"),
            "error: {}",
            value["error"]
        );
    }

    #[test]
    fn stop_failed_reports_a_restart_refusal() {
        let stopped = instance_status_doc("stopped");
        let server = serve(&[
            ("/api/v1/instances/i1", 200, &stopped),
            (
                "PATCH /api/v1/instances/i1/start",
                403,
                r#"{"errors":[{"status":"403","detail":"token is missing the required scope instances:write"}]}"#,
            ),
        ]);
        let client = ApiClient::new(&base(&server), token());
        let mut last_row = json!({"status": "running"});
        let value = stop_failed(
            &client,
            "i1",
            json!({"stop": "failed", "resize": "pending", "start": "pending"}),
            &mut last_row,
            "stop timed out".to_string(),
            json!({}),
            true,
        );
        assert_eq!(value["steps"]["start"], "failed");
        assert_eq!(value["started"], false);
        assert!(
            value["start_error"]
                .as_str()
                .unwrap()
                .contains("instances:write"),
            "start_error: {}",
            value["start_error"]
        );
    }

    #[test]
    fn resize_failed_reports_a_start_refusal_when_the_row_stays_stopped() {
        let stopped = instance_status_doc("stopped");
        let server = serve(&[
            ("/api/v1/instances/i1", 200, &stopped),
            (
                "PATCH /api/v1/instances/i1/start",
                403,
                r#"{"errors":[{"status":"403","detail":"token is missing the required scope instances:write"}]}"#,
            ),
        ]);
        let client = ApiClient::new(&base(&server), token());
        let mut steps = json!({"stop": "done", "resize": "failed", "start": "pending"});
        let mut last_row = json!({"status": "stopped"});
        let value = resize_failed(
            &client,
            "i1",
            &mut steps,
            &mut last_row,
            "resize refused".to_string(),
            json!({}),
            true,
        );
        assert_eq!(value["steps"]["start"], "failed");
        assert_eq!(value["started"], false);
        assert!(
            value["start_error"]
                .as_str()
                .unwrap()
                .contains("instances:write"),
            "start_error: {}",
            value["start_error"]
        );
    }

    #[test]
    fn resize_failed_treats_a_racing_start_refusal_as_done() {
        let starting = instance_status_doc("starting");
        let server = serve(&[
            ("/api/v1/instances/i1", 200, &starting),
            (
                "PATCH /api/v1/instances/i1/start",
                400,
                r#"{"errors":[{"detail":"cannot start instance in starting state"}]}"#,
            ),
        ]);
        let client = ApiClient::new(&base(&server), token());
        let mut steps = json!({"stop": "done", "resize": "failed", "start": "pending"});
        let mut last_row = json!({"status": "stopped"});
        let value = resize_failed(
            &client,
            "i1",
            &mut steps,
            &mut last_row,
            "resize failed".to_string(),
            json!({}),
            true,
        );
        assert_eq!(value["steps"]["start"], "skipped");
        assert_eq!(value["started"], true);
        assert_eq!(value["start_error"], Value::Null);
        assert!(
            (0..server.head_count())
                .map(|n| server.head(n).to_lowercase())
                .any(|head| head.starts_with("patch /api/v1/instances/i1/start"))
        );
    }

    #[tokio::test]
    async fn a_stop_5xx_restarts_the_row_it_may_have_stopped() {
        let server = script(vec![
            respond_envelope("200 OK", json!({"data": instance_row("i1", "running")})),
            respond(
                "500 Internal Server Error",
                r#"{"errors":[{"status":"500","title":"SomethingWentWrong","detail":"boom"}]}"#,
            ),
            respond_envelope("200 OK", json!({"data": instance_row("i1", "stopped")})),
            respond_envelope("200 OK", json!({"data": instance_row("i1", "starting")})),
            respond_envelope("200 OK", json!({"data": instance_row("i1", "starting")})),
        ]);
        let value = instances_resize(
            base_of(&server),
            token(),
            "i1".into(),
            None,
            Some(2048),
            None,
        )
        .await
        .unwrap();
        assert_eq!(value["ok"], false);
        assert_eq!(value["step"], "stop");
        assert_eq!(value["steps"]["stop"], "done");
        assert_eq!(value["steps"]["resize"], "not_attempted");
        assert_eq!(value["steps"]["start"], "done");
        assert_eq!(value["started"], true);
        assert!(
            value["error"].as_str().unwrap().contains("restarted"),
            "error: {}",
            value["error"]
        );
        assert!(
            captured_requests(&server)
                .iter()
                .any(|request| request.starts_with("patch /api/v1/instances/i1/start"))
        );
    }

    #[tokio::test]
    async fn a_stop_4xx_does_not_restart_a_row_it_did_not_stop() {
        let server = script(vec![
            respond_envelope("200 OK", json!({"data": instance_row("i1", "running")})),
            respond(
                "400 Bad Request",
                r#"{"errors":[{"status":"400","title":"Invalid","detail":"cannot stop instance in stopped state (must be running)"}]}"#,
            ),
            respond_envelope("200 OK", json!({"data": instance_row("i1", "stopped")})),
            respond_envelope("200 OK", json!({"data": instance_row("i1", "stopped")})),
        ]);
        let value = instances_resize(
            base_of(&server),
            token(),
            "i1".into(),
            None,
            Some(2048),
            None,
        )
        .await
        .unwrap();
        assert_eq!(value["ok"], false);
        assert_eq!(value["steps"]["stop"], "failed");
        assert_eq!(value["steps"]["start"], "not_attempted");
        assert_eq!(value["started"], false);
        assert!(!value["error"].as_str().unwrap().contains("restarted"));
        assert!(
            captured_requests(&server)
                .iter()
                .all(|request| !request.starts_with("patch /api/v1/instances/i1/start"))
        );
    }

    #[tokio::test]
    async fn a_start_5xx_that_landed_is_not_reported_as_a_failure() {
        let resized = json!({"data": {"type": "instance", "id": "i1",
            "attributes": {"id": "i1", "status": "stopped", "cpu_cores": "2",
                           "memory_mb": 2048, "storage_gb": 10}}});
        let quote = json!({"cpu_cores": "2", "memory_mb": 2048, "storage_gb": 10,
                           "monthly_cents": 900, "stopped_monthly_cents": 40,
                           "monthly": "$9.00/mo", "stopped": "$0.40 while stopped"});
        let server = script(vec![
            respond_envelope("200 OK", json!({"data": instance_row("i1", "running")})),
            respond_envelope("200 OK", json!({"data": instance_row("i1", "stopped")})),
            respond_envelope("200 OK", resized),
            respond(
                "500 Internal Server Error",
                r#"{"errors":[{"status":"500","title":"SomethingWentWrong","detail":"start boom"}]}"#,
            ),
            respond_envelope("200 OK", quote),
            respond_envelope("200 OK", json!({"data": instance_row("i1", "starting")})),
            respond_envelope("200 OK", json!({"data": instance_row("i1", "starting")})),
        ]);
        let value = instances_resize(
            base_of(&server),
            token(),
            "i1".into(),
            Some("2".into()),
            Some(2048),
            None,
        )
        .await
        .unwrap();
        assert_eq!(value["ok"], true);
        assert_eq!(value["steps"]["start"], "skipped");
        assert_eq!(value["started"], true);
        assert_eq!(value["error"], Value::Null);
        assert_eq!(value["price"]["monthly_cents"], 900);
    }

    #[test]
    fn allocation_precheck_matches_the_platforms_refusals() {
        let row = json!({"cpu_cores": "0.5", "memory_mb": 512, "storage_gb": 10});
        assert_eq!(
            allocation_precheck(&row, None, Some(512), None).unwrap(),
            "400 Invalid: allocation is unchanged"
        );
        assert_eq!(
            allocation_precheck(&row, Some("0.50"), None, None).unwrap(),
            "400 Invalid: allocation is unchanged"
        );
        assert_eq!(
            allocation_precheck(&row, None, None, Some(5)).unwrap(),
            "400 Invalid: storage can never shrink (from 10 GB to 5 GB)"
        );
        // A real change and an unknowable current dimension pass
        // through to the server.
        assert!(allocation_precheck(&row, None, Some(2048), None).is_none());
        assert!(allocation_precheck(&row, Some("2"), None, None).is_none());
        assert!(allocation_precheck(&json!({}), None, Some(512), None).is_none());
    }

    #[test]
    fn gateway_after_pairing_reports_a_missing_row_beside_the_pairing() {
        let server = serve(&[(
            "/api/v1/organizations/01JORG1/access-gateway",
            404,
            r#"{"errors":[]}"#,
        )]);
        let client = ApiClient::new(&base(&server), token());
        let (gateway, error) = gateway_after_pairing(&client, "01JORG1");
        assert_eq!(gateway, Value::Null);
        assert!(
            error
                .as_str()
                .unwrap()
                .contains("not found after the pairing"),
            "error: {error}"
        );
    }

    #[test]
    fn safe_segment_refuses_the_path_shaping_characters() {
        assert!(safe_segment("slug", "ok-slug").is_ok());
        for bad in ["", "a/b", "a?b", "a#b", "a%b", "..", "a b"] {
            assert!(safe_segment("slug", bad).is_err(), "{bad:?} must refuse");
        }
    }

    #[test]
    fn safe_query_value_refuses_only_query_reshaping_values() {
        // Real cursors (base64url, `%` escapes, even `/`) pass; only
        // what would reshape the request refuses.
        for ok in ["Q1VCUw", "Y3Vyc29y%2B", "a/b", "..", "a?b", "a-b_c~.'*()"] {
            assert!(
                safe_query_value("ledger cursor", ok).is_ok(),
                "{ok:?} passes"
            );
        }
        for bad in ["", "a&limit=100", "a#fragment", "a b", "a\tb"] {
            assert!(
                safe_query_value("ledger cursor", bad).is_err(),
                "{bad:?} must refuse"
            );
        }
    }
}
