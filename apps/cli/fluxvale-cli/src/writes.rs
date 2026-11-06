//! The write commands: the instance lifecycle (T5 of #362) — deploy
//! (create + the deploy PATCH), stop, start, destroy — and backups —
//! configure, status, run, restore — and access — status, attach,
//! detach, resume. Same posture as the reads (T4): a thin client over
//! /api/v1; every decision (the guards, the wallet gates, the field
//! validation) stays server-side and the API's own words surface
//! verbatim (ADR-0019 Am. 3). The destructive verbs gate on
//! `--confirm` locally: without the flag NOTHING is sent; the command
//! prints what would happen and the exact re-run command (restore
//! overwrites the volume; destroy deletes the instance and all its
//! data). Gateway create stays out (it holds a Tailscale auth key and
//! provisions cluster resources — the panel's flow, ADR-0039).

use crate::cli::Output;
use crate::human;
use crate::reads::{
    deployed_cell, friendly_404, get_or_404, now_secs, one_resource, safe_segment, status_line,
    with_id,
};
use crate::render::{Detail, cell, to_pretty, yes_no};
use fluxvale_api::{ApiClient, ApiError, Document, Resource};
use serde_json::{Value, json};

// ---- the instance lifecycle (T5 of #362): deploy, stop, start,
// destroy. The version id is the wire's own currency: the app row
// carries no versions, but GET /apps/:app_id/versions lists them
// (newest first) — so `--version` is that route's resource id and a
// plain `--app` deploys the newest published one, the choice always
// named in the output.

/// The `instances deploy` flags as parsed — the create body's source.
/// `env_vars` is deliberately absent: the create route's wire schema
/// refuses it (hide_fields strips it in both directions —
/// instance_route_test), so the API cannot set env vars today.
pub struct DeployFlags {
    pub app: String,
    pub name: Option<String>,
    /// CPU cores — the wire's decimal rides as a string ("0.5").
    pub cpu: Option<String>,
    pub memory_mb: Option<i64>,
    pub storage_gb: Option<i64>,
    /// The app version id; `None` takes the newest published.
    pub version: Option<String>,
}

/// `instances deploy --app <slug>` — resolve the app, resolve the
/// version, POST the create, PATCH the deploy. The funded-gate 403
/// surfaces verbatim (it names the wallet requirement).
pub fn instances_deploy(
    client: &ApiClient,
    flags: &DeployFlags,
    output: Output,
) -> anyhow::Result<String> {
    safe_segment("app slug", &flags.app)?;
    let app = one_resource(
        get_or_404(client, &format!("/apps/{}", flags.app), "app")?,
        "app",
    )?;
    let versions = client.get(&format!("/apps/{}/versions", app.id))?;
    let (version_id, version_label) =
        resolve_version(&flags.app, flags.version.as_deref(), versions.resources())?;

    let body = json!({
        "data": {"type": "instance", "attributes": deploy_attributes(flags, &version_id)}
    });
    let created = client.send("POST", "/instances", Some(body.to_string()))?;
    let instance = one_resource(created, "instance")?;
    let deploy_body = json!({
        "data": {"type": "instance", "id": instance.id, "attributes": {}}
    });
    let deployed = client.send(
        "PATCH",
        &format!("/instances/{}/deploy", instance.id),
        Some(deploy_body.to_string()),
    )?;
    deploy_rendered(deployed, &flags.app, &version_label, output)
}

/// `--version` must be one of the app's own (a foreign id would deploy
/// a different app's blueprint silently — the server derives from the
/// version row alone). Without the flag: the newest published (the
/// wire's own newest-first order); none published is a refusal.
fn resolve_version(
    slug: &str,
    flag: Option<&str>,
    versions: Vec<Resource>,
) -> anyhow::Result<(String, String)> {
    let catalog = |versions: &[Resource]| {
        versions
            .iter()
            .map(|version| {
                format!(
                    "    {}  {}",
                    version.id,
                    cell(version.attributes.get("version"))
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    };
    let take = |version: &Resource| -> (String, String) {
        (
            version.id.clone(),
            cell(version.attributes.get("version")).trim().to_string(),
        )
    };
    match flag {
        Some(id) => versions
            .iter()
            .find(|version| version.id == id)
            .map(take)
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "version {id} is not a version of {slug} — pick one:\n{}",
                    catalog(&versions)
                )
            }),
        None => match versions.len() {
            0 => anyhow::bail!("{slug} has no published versions"),
            _ => Ok(take(versions.first().expect("len checked above"))),
        },
    }
}

/// The create body's attributes: the resolved version always; the
/// resource flags only when given, so absent keys take the version's
/// own defaults (catalog defaults apply server-side). `env_vars` is
/// never here — see [`DeployFlags`].
fn deploy_attributes(flags: &DeployFlags, version_id: &str) -> Value {
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
    attrs
}

fn deploy_rendered(
    document: Document,
    slug: &str,
    version_label: &str,
    output: Output,
) -> anyhow::Result<String> {
    let resource = one_resource(document, "instance")?;
    let attrs = with_id(&resource);
    let mut detail = Detail::new(attrs.clone());
    detail.field("id", cell(attrs.get("id")));
    detail.field("name", cell(attrs.get("name")));
    detail.field("slug", cell(attrs.get("slug")));
    detail.field("status", cell(attrs.get("status")));
    detail.field("image", cell(attrs.get("image")));
    detail.field("cpu cores", cell(attrs.get("cpu_cores")));
    detail.field("memory (MB)", cell(attrs.get("memory_mb")));
    detail.field("storage (GB)", cell(attrs.get("storage_gb")));
    let mut rendered = detail.render(output);
    if output == Output::Table {
        let id = attrs.get("id").and_then(Value::as_str).unwrap_or("");
        rendered.push_str(&format!(
            "\ndeploying {slug} {version_label} — watch with: fluxvale instances status {id}"
        ));
    }
    Ok(rendered)
}

/// `instances stop <id>` / `instances start <id>` — the PATCH verbs;
/// the response row's status IS the transition.
pub fn instances_stop(client: &ApiClient, id: &str, output: Output) -> anyhow::Result<String> {
    lifecycle_patch(client, id, "stop", output)
}

pub fn instances_start(client: &ApiClient, id: &str, output: Output) -> anyhow::Result<String> {
    lifecycle_patch(client, id, "start", output)
}

fn lifecycle_patch(
    client: &ApiClient,
    id: &str,
    verb: &str,
    output: Output,
) -> anyhow::Result<String> {
    safe_segment("instance id", id)?;
    let body = json!({"data": {"type": "instance", "id": id, "attributes": {}}});
    let document = client
        .send(
            "PATCH",
            &format!("/instances/{id}/{verb}"),
            Some(body.to_string()),
        )
        .map_err(|err| friendly_404(err, "instance"))?;
    let resource = one_resource(document, "instance")?;
    let attrs = with_id(&resource);
    let mut detail = Detail::new(attrs.clone());
    detail.field("id", cell(attrs.get("id")));
    detail.field("name", cell(attrs.get("name")));
    detail.field("slug", cell(attrs.get("slug")));
    detail.field("status", cell(attrs.get("status")));
    let mut rendered = detail.render(output);
    if output == Output::Table {
        let status = attrs.get("status").and_then(Value::as_str).unwrap_or("");
        rendered.push('\n');
        rendered.push_str(&status_line(status));
    }
    Ok(rendered)
}

/// `instances destroy <id> [--confirm]` — the destructive verb.
/// WITHOUT `--confirm` nothing is sent: the command prints what will
/// be lost and the exact re-run command, then exits non-zero; the
/// refusal arm spends no request (the restore gate's shape). WITH
/// `--confirm`, the DELETE rides and the server's own answer prints
/// (deployed rows land `deleting` — the teardown runs async).
pub fn instances_destroy(
    client: &ApiClient,
    id: &str,
    confirm: bool,
    output: Output,
) -> anyhow::Result<String> {
    safe_segment("instance id", id)?;
    if !confirm {
        anyhow::bail!(
            "destroy instance {id} — all data on it is deleted; nothing was sent\n\
             re-run with --confirm to proceed:\n    \
             fluxvale instances destroy {id} --confirm"
        );
    }
    let row = client
        .send_json("DELETE", &format!("/instances/{id}"), None)
        .map_err(|err| friendly_404(err, "instance"))?;
    destroy_rendered(&row, output)
}

fn destroy_rendered(row: &Value, output: Output) -> anyhow::Result<String> {
    let mut detail = Detail::new(row.clone());
    detail.field("id", cell(row.get("id")));
    detail.field("name", cell(row.get("name")));
    detail.field("status", cell(row.get("status")));
    let mut rendered = detail.render(output);
    if output == Output::Table {
        let status = row.get("status").and_then(Value::as_str).unwrap_or("");
        rendered.push('\n');
        rendered.push_str(&status_line(status));
    }
    Ok(rendered)
}

/// The runs history read's query. `limit` is the read action's own
/// argument (1..100, default 20 in Ash — but REQUIRED on the wire:
/// the route 400s "limit is required" without it), and it is the only
/// pagination there is (newest first, no cursor). The status read
/// wants only the newest row.
pub(crate) const RUNS_PAGE_QUERY: &str = "?limit=1";

/// The `backups configure` flags as parsed — the write payload's
/// source. `enabled: None` means neither `--enabled` nor `--disabled`
/// was passed: create takes the server's default (true), an update
/// leaves the row's value alone (the MCP tool's own semantics — a
/// plain re-configure must not silently re-enable a paused row).
pub struct ConfigureBackup {
    pub instance: String,
    pub endpoint: String,
    pub bucket: String,
    pub prefix: Option<String>,
    pub access_key_id: String,
    pub retention: Option<u8>,
    pub enabled: Option<bool>,
}

/// The `--enabled/--disabled` pair folded to the payload's tri-state.
pub fn enabled_flag(enabled: bool, disabled: bool) -> Option<bool> {
    match (enabled, disabled) {
        (true, _) => Some(true),
        (_, true) => Some(false),
        (false, false) => None,
    }
}

/// `backups configure <instance>` — create-or-update, the MCP tool's
/// semantics: read the row first; a 404 (unconfigured — or a row a
/// read couldn't return, which the create arm's unique-constraint
/// error then surfaces) posts a new row, an existing row patches.
/// Field validation is the server's; its errors surface verbatim.
pub fn backups_configure(
    client: &ApiClient,
    flags: &ConfigureBackup,
    output: Output,
) -> anyhow::Result<String> {
    safe_segment("instance id", &flags.instance)?;
    let retention = flags.retention.map(checked_retention).transpose()?;
    let attrs = setting_attributes(
        &flags.endpoint,
        &flags.bucket,
        flags.prefix.as_deref(),
        &flags.access_key_id,
        retention,
        flags.enabled,
    );

    match client.get(&format!("/instances/{}/backup-setting", flags.instance)) {
        // The create arm: instance_id rides the PATH, never the body —
        // the body schema refuses a copy (backup_route_test).
        Err(ApiError::NotFound) => {
            let body = json!({"data": {"type": "backup_setting", "attributes": attrs}});
            let document = client.send(
                "POST",
                &format!("/instances/{}/backup-setting", flags.instance),
                Some(body.to_string()),
            )?;
            configure_rendered(document, output)
        }
        // Any other read failure (forbidden, offline) passes through.
        Err(err) => Err(err.into()),
        Ok(document) => {
            let setting = one_resource(document, "backup setting")?;
            let body = json!({
                "data": {
                    "type": "backup_setting",
                    "id": setting.id,
                    "attributes": attrs,
                }
            });
            let updated = client.send(
                "PATCH",
                &format!("/backup-settings/{}", setting.id),
                Some(body.to_string()),
            )?;
            configure_rendered(updated, output)
        }
    }
}

/// The settings row's attributes as the write body carries them: the
/// required coordinates always; prefix/retention/enabled only when
/// given, so absent keys leave the server's default (create) or the
/// row's value (update) alone. `instance_id` is deliberately absent —
/// the create route's body schema refuses it outright.
fn setting_attributes(
    endpoint: &str,
    bucket: &str,
    prefix: Option<&str>,
    access_key_id: &str,
    retention: Option<Value>,
    enabled: Option<bool>,
) -> Value {
    let mut attrs = json!({
        "endpoint": endpoint,
        "bucket": bucket,
        "access_key_id": access_key_id,
    });
    if let Some(prefix) = prefix {
        attrs["prefix"] = json!(prefix);
    }
    if let Some(retention) = retention {
        attrs["retention_keep"] = retention;
    }
    if let Some(enabled) = enabled {
        attrs["enabled"] = json!(enabled);
    }
    attrs
}

/// The retention flag's fence — restic `forget --keep-last N`; the
/// same 2..30 bound the resource enforces, checked here so a bad
/// value never rides the wire.
fn checked_retention(retention: u8) -> anyhow::Result<Value> {
    if (2..=30).contains(&retention) {
        Ok(json!(retention))
    } else {
        anyhow::bail!("invalid --retention {retention}: keep between 2 and 30 snapshots")
    }
}

fn configure_rendered(document: Document, output: Output) -> anyhow::Result<String> {
    let resource = one_resource(document, "backup setting")?;
    let attrs = with_id(&resource);
    let mut detail = Detail::new(attrs.clone());
    detail.field("id", cell(attrs.get("id")));
    detail.field("instance", cell(attrs.get("instance_id")));
    detail.field("endpoint", cell(attrs.get("endpoint")));
    detail.field("bucket", cell(attrs.get("bucket")));
    detail.field("prefix", cell(attrs.get("prefix")));
    detail.field("access key id", cell(attrs.get("access_key_id")));
    detail.field("retention", retention_cell(attrs.get("retention_keep")));
    detail.field("enabled", yes_no(attrs.get("enabled")));
    Ok(detail.render(output))
}

/// retention_keep is restic's `--keep-last N` — the label says so.
fn retention_cell(value: Option<&Value>) -> String {
    match value.and_then(Value::as_i64) {
        Some(keep) => format!("keep {keep}"),
        None => "-".to_string(),
    }
}

/// `backups status <instance>` — the instance read first (a GET 404s
/// a foreign or missing id), then the settings row (or "not
/// configured") plus the LATEST run. The runs read itself cannot name
/// a foreign instance: it is an index, and the policy FILTERS rows it
/// can't see instead of 404ing — a foreign id answers 200 with an
/// empty list.
pub fn backups_status(
    client: &ApiClient,
    instance: &str,
    output: Output,
) -> anyhow::Result<String> {
    safe_segment("instance id", instance)?;
    get_or_404(client, &format!("/instances/{instance}"), "instance")?;
    let setting = match client.get(&format!("/instances/{instance}/backup-setting")) {
        Err(ApiError::NotFound) => None,
        Err(err) => return Err(err.into()),
        Ok(document) => Some(one_resource(document, "backup setting")?),
    };
    let runs = client.get(&format!(
        "/instances/{instance}/backup-runs{RUNS_PAGE_QUERY}"
    ))?;
    let latest_run = runs.resources().into_iter().next();

    status_rendered(setting, latest_run, output, now_secs())
}

fn status_rendered(
    setting: Option<Resource>,
    latest_run: Option<Resource>,
    output: Output,
    now: i64,
) -> anyhow::Result<String> {
    if output == Output::Json {
        let mut map = serde_json::Map::new();
        map.insert(
            "backup_setting".to_string(),
            setting.as_ref().map(with_id).unwrap_or(Value::Null),
        );
        map.insert(
            "latest_run".to_string(),
            latest_run.as_ref().map(with_id).unwrap_or(Value::Null),
        );
        return Ok(to_pretty(&Value::Object(map)));
    }

    // The table answer: leading sentences (the not-configured case,
    // the no-runs case) outside ONE grid, so every field line shares
    // a width.
    let mut lines: Vec<String> = Vec::new();
    let mut detail = Detail::new(Value::Null);
    let mut grid_has_fields = false;

    if let Some(setting) = &setting {
        grid_has_fields = true;
        let attrs = with_id(setting);
        detail.field("endpoint", cell(attrs.get("endpoint")));
        detail.field("bucket", cell(attrs.get("bucket")));
        detail.field("prefix", cell(attrs.get("prefix")));
        detail.field("access key id", cell(attrs.get("access_key_id")));
        detail.field("retention", retention_cell(attrs.get("retention_keep")));
        detail.field("enabled", yes_no(attrs.get("enabled")));
    } else {
        lines.push("backups are not configured for this instance".to_string());
    }

    let mut no_runs = false;
    match &latest_run {
        None => no_runs = true,
        Some(run) => {
            grid_has_fields = true;
            detail_with_run(&mut detail, run, now);
        }
    }
    if grid_has_fields {
        lines.push(detail.render(output));
    }
    if no_runs {
        lines.push("no backup runs yet".to_string());
    }
    Ok(lines.join("\n"))
}

/// The run's fields onto a status grid.
fn detail_with_run(detail: &mut Detail, run: &Resource, now: i64) {
    let attrs = with_id(run);
    detail.field(
        "latest run",
        run_line(attrs.get("kind"), attrs.get("status")),
    );
    // The snapshot id and the finish are the facts the restore
    // command's --from names.
    detail.field("snapshot", cell(attrs.get("snapshot_id")));
    detail.field("started", deployed_cell(attrs.get("started_at"), now));
    detail.field("finished", deployed_cell(attrs.get("finished_at"), now));
    if attrs.get("status").and_then(Value::as_str) == Some("failed") {
        detail.field("error", cell(attrs.get("error_summary")));
    }
}

/// One run's identity line: "manual, succeeded".
fn run_line(kind: Option<&Value>, status: Option<&Value>) -> String {
    let kind = kind.and_then(Value::as_str);
    let status = status.and_then(Value::as_str);
    match (kind, status) {
        (Some(kind), Some(status)) => format!("{kind}, {status}"),
        (Some(kind), None) => kind.to_string(),
        (None, Some(status)) => status.to_string(),
        (None, None) => "-".to_string(),
    }
}

/// `backups run <instance>` — POST the manual run. A refusal surfaces
/// the operation's own words (the guard atoms' plain copy on the
/// wire); the returned row prints as-is.
pub fn backups_run(client: &ApiClient, instance: &str, output: Output) -> anyhow::Result<String> {
    safe_segment("instance id", instance)?;
    let run = client
        .send_json("POST", &format!("/instances/{instance}/backup-runs"), None)
        .map_err(|err| friendly_404(err, "instance"))?;
    run_rendered(&run, instance, output, now_secs())
}

fn run_rendered(run: &Value, instance: &str, output: Output, now: i64) -> anyhow::Result<String> {
    let mut detail = Detail::new(run.clone());
    detail.field("id", cell(run.get("id")));
    detail.field("kind", cell(run.get("kind")));
    detail.field("status", cell(run.get("status")));
    detail.field("instance", cell(run.get("instance_id")));
    detail.field("started", deployed_cell(run.get("started_at"), now));
    let mut rendered = detail.render(output);
    if output == Output::Table {
        rendered.push_str(&format!(
            "\nthe run is queued — `fluxvale backups status {instance}` tracks the finish"
        ));
    }
    Ok(rendered)
}

/// `backups restore <instance> --from <run> [--confirm]` — the
/// destructive verb. WITHOUT `--confirm` nothing is sent: the command
/// prints the target, the overwrite warning, and the exact re-run
/// command, then exits non-zero. The run's snapshot id and finish
/// live one read away in `backups status`; the refusal arm spends no
/// request. WITH `--confirm`, the POST rides and the returned restore
/// row prints.
pub fn backups_restore(
    client: &ApiClient,
    instance: &str,
    from: &str,
    confirm: bool,
    output: Output,
) -> anyhow::Result<String> {
    safe_segment("instance id", instance)?;
    safe_segment("backup run id", from)?;
    if !confirm {
        anyhow::bail!(
            "restore run {from} onto instance {instance} — the current volume state is \
             OVERWRITTEN; nothing was sent\n\
             re-run with --confirm to proceed:\n    \
             fluxvale backups restore {instance} --from {from} --confirm"
        );
    }
    let run = client
        .send_json(
            "POST",
            &format!("/instances/{instance}/backup-runs/{from}/restore"),
            None,
        )
        .map_err(|err| friendly_404(err, "backup run"))?;
    restore_rendered(&run, instance, output, now_secs())
}

fn restore_rendered(
    run: &Value,
    instance: &str,
    output: Output,
    now: i64,
) -> anyhow::Result<String> {
    let mut detail = Detail::new(run.clone());
    detail.field("id", cell(run.get("id")));
    detail.field("kind", cell(run.get("kind")));
    detail.field("status", cell(run.get("status")));
    detail.field("instance", cell(run.get("instance_id")));
    detail.field("restored from", cell(run.get("restored_from")));
    detail.field("started", deployed_cell(run.get("started_at"), now));
    let mut rendered = detail.render(output);
    if output == Output::Table {
        rendered.push_str(&format!(
            "\nthe restore runs server-side — `fluxvale backups status {instance}` tracks the finish"
        ));
    }
    Ok(rendered)
}

/// `access status` — the org's gateway, resolved like the wallet
/// commands' org, or the 404's line ("no gateway").
pub fn access_status(client: &ApiClient, org_id: &str, output: Output) -> anyhow::Result<String> {
    safe_segment("organization id", org_id)?;
    let document = client
        .get(&format!("/organizations/{org_id}/access-gateway"))
        .map_err(|err| match err {
            ApiError::NotFound => {
                anyhow::anyhow!("no gateway for this organization (or you're not a member)")
            }
            other => other.into(),
        })?;
    let resource = one_resource(document, "access gateway")?;
    let attrs = with_id(&resource);
    let mut detail = Detail::new(attrs.clone());
    detail.field("id", cell(attrs.get("id")));
    detail.field("organization", cell(attrs.get("organization_id")));
    detail.field("hostname", cell(attrs.get("hostname")));
    detail.field("tailnet domain", cell(attrs.get("tailnet_domain")));
    detail.field("provider", cell(attrs.get("provider")));
    detail.field("state", cell(attrs.get("state")));
    detail.field("status message", cell(attrs.get("status_message")));
    detail.field("monthly", money_cell(attrs.get("monthly_cents")));
    detail.field(
        "provisioned",
        deployed_cell(attrs.get("provisioned_at"), now_secs()),
    );
    Ok(detail.render(output))
}

/// `access attach <gateway> <instance>` — the pairing POST; the flat
/// route row prints (gateway, instance, route key).
pub fn access_attach(
    client: &ApiClient,
    gateway: &str,
    instance: &str,
    output: Output,
) -> anyhow::Result<String> {
    safe_segment("gateway id", gateway)?;
    safe_segment("instance id", instance)?;
    let body = json!({"data": {"instance_id": instance}});
    let route = client
        .send_json(
            "POST",
            &format!("/access-gateways/{gateway}/attachments"),
            Some(body.to_string()),
        )
        .map_err(friendly_pairing_404)?;
    let mut detail = Detail::new(route.clone());
    detail.field("gateway", cell(route.get("gateway_id")));
    detail.field("instance", cell(route.get("instance_id")));
    detail.field("route key", cell(route.get("route_key")));
    Ok(detail.render(output))
}

/// `access detach <gateway> <instance>` — idempotent, like the
/// panel's; the wire answers {"success": true} and the command a
/// plain line.
pub fn access_detach(
    client: &ApiClient,
    gateway: &str,
    instance: &str,
    output: Output,
) -> anyhow::Result<String> {
    safe_segment("gateway id", gateway)?;
    safe_segment("instance id", instance)?;
    let answer = client
        .send_json(
            "DELETE",
            &format!("/access-gateways/{gateway}/attachments/{instance}"),
            None,
        )
        .map_err(friendly_pairing_404)?;
    Ok(match output {
        Output::Table => "detached".to_string(),
        Output::Json => to_pretty(&answer),
    })
}

/// Both pairing verbs re-read the gateway AND the instance, so a 404
/// cannot say which side missed — the line stays honest about that.
fn friendly_pairing_404(err: ApiError) -> anyhow::Error {
    match err {
        ApiError::NotFound => anyhow::anyhow!("no such gateway or instance (or it's not yours)"),
        other => other.into(),
    }
}

/// `access resume <gateway>` — the funded resume: scale back up and
/// reopen the billing anchor; the gateway row comes back.
pub fn access_resume(client: &ApiClient, gateway: &str, output: Output) -> anyhow::Result<String> {
    safe_segment("gateway id", gateway)?;
    let body = json!({"data": {"type": "access_gateway", "id": gateway, "attributes": {}}});
    let document = client
        .send(
            "PATCH",
            &format!("/access-gateways/{gateway}/resume"),
            Some(body.to_string()),
        )
        .map_err(|err| friendly_404(err, "gateway"))?;
    let resource = one_resource(document, "access gateway")?;
    let attrs = with_id(&resource);
    let mut detail = Detail::new(attrs.clone());
    detail.field("id", cell(attrs.get("id")));
    detail.field("hostname", cell(attrs.get("hostname")));
    detail.field("state", cell(attrs.get("state")));
    detail.field("status message", cell(attrs.get("status_message")));
    detail.field("monthly", money_cell(attrs.get("monthly_cents")));
    Ok(detail.render(output))
}

/// `access create` stays out of the CLI: the create holds a Tailscale
/// auth key and provisions cluster resources synchronously — the
/// panel's flow (ADR-0039). The stub answers where to go.
pub fn access_create_unavailable() -> anyhow::Result<String> {
    anyhow::bail!(
        "creating a gateway needs a Tailscale auth key and provisions cluster resources \
         — use the panel's Access tab"
    )
}

fn money_cell(value: Option<&Value>) -> String {
    match value.and_then(Value::as_i64) {
        Some(cents) => human::money(cents),
        None => "-".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::VecDeque;
    use std::io::{Read as _, Write as _};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    const NOW: i64 = 1793836800; // 2026-11-05T00:00:00Z

    fn document(value: serde_json::Value) -> Document {
        serde_json::from_value(value).unwrap()
    }

    /// The single resource of a one-resource envelope.
    fn resource(value: serde_json::Value) -> Resource {
        let mut resources = document(json!({"data": value})).resources();
        assert_eq!(resources.len(), 1, "fixture must parse into one resource");
        resources.remove(0)
    }

    fn setting_row() -> serde_json::Value {
        json!({
            "type": "backup_setting", "id": "set1",
            "attributes": {
                "id": "set1", "instance_id": "i1",
                "endpoint": "https://account.r2.cloudflarestorage.com",
                "bucket": "fluxvale-kavita", "prefix": "fluxvale/app",
                "access_key_id": "AKIAIOSFODNN7EXAMPLE",
                "retention_keep": 7, "enabled": true
            }
        })
    }

    fn setting_row_with_retention(keep: i64) -> serde_json::Value {
        let mut row = setting_row();
        row["attributes"]["retention_keep"] = json!(keep);
        row
    }

    fn succeeded_run() -> serde_json::Value {
        json!({
            "type": "backup_run", "id": "r9",
            "attributes": {
                "id": "r9", "instance_id": "i1", "kind": "manual",
                "status": "succeeded",
                "snapshot_id": "aaaa", "error_summary": null,
                "started_at": "2026-11-04T21:00:00Z",
                "finished_at": "2026-11-04T21:02:00Z"
            }
        })
    }

    // ---- payload shapes

    #[test]
    fn setting_attributes_carry_the_required_coordinates_and_only_given_optionals() {
        let attrs = setting_attributes("https://e.example", "bucket", None, "KEY", None, None);
        assert_eq!(
            attrs,
            json!({"endpoint": "https://e.example", "bucket": "bucket", "access_key_id": "KEY"})
        );
        // instance_id is NEVER in the body — the create route's body
        // schema refuses it; the path is the only intake.
        assert!(attrs.get("instance_id").is_none());

        let full = setting_attributes(
            "https://e.example",
            "bucket",
            Some("a/b"),
            "KEY",
            Some(json!(14)),
            Some(false),
        );
        assert_eq!(
            full,
            json!({
                "endpoint": "https://e.example", "bucket": "bucket", "access_key_id": "KEY",
                "prefix": "a/b", "retention_keep": 14, "enabled": false
            })
        );
    }

    #[test]
    fn retention_is_fenced_to_the_resource_bound_locally() {
        assert_eq!(checked_retention(2).unwrap(), json!(2));
        assert_eq!(checked_retention(30).unwrap(), json!(30));
        let err = checked_retention(1).unwrap_err();
        assert!(err.to_string().contains("between 2 and 30"), "err: {err}");
        assert!(checked_retention(31).is_err());
    }

    #[test]
    fn the_enabled_disabled_pair_folds_to_a_tri_state() {
        assert_eq!(enabled_flag(false, false), None);
        assert_eq!(enabled_flag(true, false), Some(true));
        assert_eq!(enabled_flag(false, true), Some(false));
    }

    #[test]
    fn a_retention_outside_2_30_is_refused_before_any_request() {
        // The client points at a dead port: a wire call would fail
        // with a transport error, so reaching "invalid --retention"
        // proves the fence fired first.
        let client = client("http://127.0.0.1:1");
        let flags = ConfigureBackup {
            instance: "i1".into(),
            endpoint: "https://e.example".into(),
            bucket: "bucket".into(),
            prefix: None,
            access_key_id: "KEY".into(),
            retention: Some(31),
            enabled: None,
        };
        let err = backups_configure(&client, &flags, Output::Table).unwrap_err();
        assert!(
            err.to_string().contains("invalid --retention 31"),
            "err: {err}"
        );
    }

    // ---- fixture-render tests

    #[test]
    fn configure_renders_the_saved_row() {
        let rendered =
            configure_rendered(document(json!({"data": setting_row()})), Output::Table).unwrap();
        assert_eq!(
            rendered,
            "id             set1\n\
             instance       i1\n\
             endpoint       https://account.r2.cloudflarestorage.com\n\
             bucket         fluxvale-kavita\n\
             prefix         fluxvale/app\n\
             access key id  AKIAIOSFODNN7EXAMPLE\n\
             retention      keep 7\n\
             enabled        yes"
        );
    }

    #[test]
    fn configure_json_is_the_raw_attrs() {
        let rendered =
            configure_rendered(document(json!({"data": setting_row()})), Output::Json).unwrap();
        let attrs: Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(attrs["bucket"], "fluxvale-kavita");
        assert_eq!(attrs["id"], "set1");
    }

    #[test]
    fn status_renders_the_settings_row_and_the_latest_run() {
        let rendered = status_rendered(
            Some(resource(setting_row())),
            Some(resource(succeeded_run())),
            Output::Table,
            NOW,
        )
        .unwrap();
        assert_eq!(
            rendered,
            "endpoint       https://account.r2.cloudflarestorage.com\n\
             bucket         fluxvale-kavita\n\
             prefix         fluxvale/app\n\
             access key id  AKIAIOSFODNN7EXAMPLE\n\
             retention      keep 7\n\
             enabled        yes\n\
             latest run     manual, succeeded\n\
             snapshot       aaaa\n\
             started        3h ago (2026-11-04T21:00:00Z)\n\
             finished       2h ago (2026-11-04T21:02:00Z)"
        );
    }

    #[test]
    fn status_shows_the_error_summary_of_a_failed_run() {
        let mut failed = succeeded_run();
        failed["attributes"]["status"] = json!("failed");
        failed["attributes"]["snapshot_id"] = Value::Null;
        failed["attributes"]["error_summary"] = json!("restic: exit 1 — bucket not found");

        let rendered = status_rendered(
            Some(resource(setting_row())),
            Some(resource(failed)),
            Output::Table,
            NOW,
        )
        .unwrap();
        assert!(
            rendered.contains("latest run     manual, failed"),
            "rendered:\n{rendered}"
        );
        assert!(
            rendered.contains("snapshot       -"),
            "rendered:\n{rendered}"
        );
        assert!(
            rendered.contains("error          restic: exit 1 — bucket not found"),
            "rendered:\n{rendered}"
        );
    }

    #[test]
    fn status_not_configured_reads_the_sentence_and_still_shows_the_history() {
        let rendered =
            status_rendered(None, Some(resource(succeeded_run())), Output::Table, NOW).unwrap();
        assert_eq!(
            rendered,
            "backups are not configured for this instance\n\
             latest run  manual, succeeded\n\
             snapshot    aaaa\n\
             started     3h ago (2026-11-04T21:00:00Z)\n\
             finished    2h ago (2026-11-04T21:02:00Z)"
        );

        let bare = status_rendered(None, None, Output::Table, NOW).unwrap();
        assert_eq!(
            bare,
            "backups are not configured for this instance\nno backup runs yet"
        );

        // Configured, never run: the grid, then the plain sentence.
        let no_runs =
            status_rendered(Some(resource(setting_row())), None, Output::Table, NOW).unwrap();
        assert!(
            no_runs.starts_with("endpoint       https://account.r2.cloudflarestorage.com"),
            "rendered:\n{no_runs}"
        );
        assert!(
            no_runs.ends_with("\nno backup runs yet"),
            "rendered:\n{no_runs}"
        );
    }

    #[test]
    fn status_json_is_the_two_reads_wrapped() {
        let rendered = status_rendered(
            Some(resource(setting_row())),
            Some(resource(succeeded_run())),
            Output::Json,
            NOW,
        )
        .unwrap();
        let map: Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(map["backup_setting"]["bucket"], "fluxvale-kavita");
        assert_eq!(map["latest_run"]["status"], "succeeded");

        let bare: Value =
            serde_json::from_str(&status_rendered(None, None, Output::Json, NOW).unwrap()).unwrap();
        assert_eq!(bare, json!({"backup_setting": null, "latest_run": null}));
    }

    #[test]
    fn run_rendered_prints_the_row_and_the_tracking_hint() {
        let row = json!({
            "id": "r9", "kind": "manual", "status": "running",
            "instance_id": "i1", "started_at": "2026-11-04T23:59:30Z"
        });
        let rendered = run_rendered(&row, "i1", Output::Table, NOW).unwrap();
        assert_eq!(
            rendered,
            "id        r9\n\
             kind      manual\n\
             status    running\n\
             instance  i1\n\
             started   just now (2026-11-04T23:59:30Z)\n\
             the run is queued — `fluxvale backups status i1` tracks the finish"
        );

        // JSON stays raw — no hint line.
        let json_out = run_rendered(&row, "i1", Output::Json, NOW).unwrap();
        let map: Value = serde_json::from_str(&json_out).unwrap();
        assert_eq!(map["kind"], "manual");
        assert!(!json_out.contains("queued"));
    }

    #[test]
    fn restore_rendered_prints_the_restore_row() {
        let row = json!({
            "id": "r10", "kind": "restore", "status": "running",
            "instance_id": "i1", "restored_from": "running",
            "started_at": "2026-11-04T23:58:00Z"
        });
        let rendered = restore_rendered(&row, "i1", Output::Table, NOW).unwrap();
        assert_eq!(
            rendered,
            "id             r10\n\
             kind           restore\n\
             status         running\n\
             instance       i1\n\
             restored from  running\n\
             started        2m ago (2026-11-04T23:58:00Z)\n\
             the restore runs server-side — `fluxvale backups status i1` tracks the finish"
        );
    }

    #[test]
    fn money_and_provisioned_cells_render() {
        let mut detail = Detail::new(Value::Null);
        detail.field("monthly", money_cell(Some(&json!(500))));
        detail.field(
            "provisioned",
            deployed_cell(Some(&json!("2026-11-04T21:00:00Z")), NOW),
        );
        let rendered = detail.render(Output::Table);
        assert_eq!(
            rendered,
            "monthly      $5.00\nprovisioned  3h ago (2026-11-04T21:00:00Z)"
        );
        assert_eq!(money_cell(None), "-");
        assert_eq!(retention_cell(None), "-");
        assert_eq!(retention_cell(Some(&json!(7))), "keep 7");
    }

    #[test]
    fn run_line_combines_kind_and_status_and_survives_either_missing() {
        assert_eq!(
            run_line(Some(&json!("manual")), Some(&json!("succeeded"))),
            "manual, succeeded"
        );
        assert_eq!(run_line(Some(&json!("restore")), None), "restore");
        assert_eq!(run_line(None, Some(&json!("pending"))), "pending");
        assert_eq!(run_line(None, None), "-");
    }

    #[test]
    fn access_status_json_is_the_raw_attrs() {
        let server = script(vec![envelope(json!({
            "data": {"type": "access_gateway", "id": "g1", "attributes": {
                "id": "g1", "organization_id": "org1",
                "hostname": "fv-abc123", "tailnet_domain": "example.ts.net",
                "provider": "tailscale", "state": "active",
                "status_message": "Connected", "monthly_cents": 500,
                "provisioned_at": "2026-11-04T21:00:00Z"
            }}
        }))]);
        let rendered = access_status(&client(&server.base_url), "org1", Output::Json).unwrap();
        let map: Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(map["hostname"], "fv-abc123");
        assert_eq!(map["state"], "active");
        assert_eq!(map["id"], "g1");
    }

    #[test]
    fn attach_json_is_the_flat_route_row() {
        let server = script(vec![respond(
            "201 Created",
            r#"{"gateway_id":"g1","instance_id":"i1","route_key":"8443"}"#,
        )]);
        let rendered = access_attach(&client(&server.base_url), "g1", "i1", Output::Json).unwrap();
        let map: Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(
            map,
            json!({"gateway_id": "g1", "instance_id": "i1", "route_key": "8443"})
        );
    }

    #[test]
    fn resume_json_is_the_raw_attrs() {
        let server = script(vec![envelope(json!({
            "data": {"type": "access_gateway", "id": "g1", "attributes": {
                "id": "g1", "hostname": "fv-abc123", "state": "provisioning",
                "status_message": null, "monthly_cents": 500
            }}
        }))]);
        let rendered = access_resume(&client(&server.base_url), "g1", Output::Json).unwrap();
        let map: Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(map["state"], "provisioning");
        assert_eq!(map["monthly_cents"], 500);
    }

    #[test]
    fn restore_json_is_the_raw_row_without_the_hint() {
        let row = json!({
            "id": "r10", "kind": "restore", "status": "running",
            "instance_id": "i1", "restored_from": "running"
        });
        let rendered = restore_rendered(&row, "i1", Output::Json, NOW).unwrap();
        let map: Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(map, row);
        assert!(!rendered.contains("tracks the finish"));
    }

    // ---- mock-server end-to-end: the paths, the bodies, the refusals.
    // A scripted server: one canned response per connection, every
    // request head+body captured.

    struct Script {
        base_url: String,
        requests: Arc<Mutex<Vec<String>>>,
    }

    fn script(responses: Vec<String>) -> Script {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let requests = Arc::new(Mutex::new(Vec::new()));
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

    fn envelope(body: serde_json::Value) -> String {
        respond("200 OK", &body.to_string())
    }

    fn client(base_url: &str) -> ApiClient {
        ApiClient::new(base_url, crate::token::Token::new("fvpat_testtoken"))
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

    #[test]
    fn configure_creates_through_the_404_arm_without_instance_id_in_the_body() {
        let server = script(vec![
            respond(
                "404 Not Found",
                r#"{"errors":[{"status":"404","title":"Not Found"}]}"#,
            ),
            respond(
                "201 Created",
                &json!({"data": setting_row_with_retention(14)}).to_string(),
            ),
        ]);
        let flags = ConfigureBackup {
            instance: "i1".into(),
            endpoint: "https://account.r2.cloudflarestorage.com".into(),
            bucket: "fluxvale-kavita".into(),
            prefix: Some("fluxvale/app".into()),
            access_key_id: "AKIAIOSFODNN7EXAMPLE".into(),
            retention: Some(14),
            enabled: None,
        };
        let rendered = backups_configure(&client(&server.base_url), &flags, Output::Table).unwrap();
        assert!(
            rendered.contains("retention      keep 14"),
            "rendered:\n{rendered}"
        );

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
        // The create body carries the coordinates — and NOT instance_id.
        assert!(requests[1].contains("\"endpoint\":\"https://account.r2.cloudflarestorage.com\""));
        assert!(requests[1].contains("\"retention_keep\":14"));
        assert!(
            !requests[1].contains("instance_id"),
            "req1: {}",
            requests[1]
        );
    }

    #[test]
    fn configure_patches_the_existing_row() {
        let server = script(vec![
            envelope(json!({"data": setting_row()})),
            envelope(json!({"data": setting_row()})),
        ]);
        let flags = ConfigureBackup {
            instance: "i1".into(),
            endpoint: "https://account.r2.cloudflarestorage.com".into(),
            bucket: "fluxvale-kavita".into(),
            prefix: None,
            access_key_id: "AKIAIOSFODNN7EXAMPLE".into(),
            retention: None,
            // Neither flag: the payload omits `enabled`, so a paused
            // row stays paused (the tri-state's point).
            enabled: enabled_flag(false, false),
        };
        backups_configure(&client(&server.base_url), &flags, Output::Table).unwrap();

        let requests = captured_requests(&server);
        assert!(
            requests[1].starts_with("patch /api/v1/backup-settings/set1 http/1.1"),
            "req1: {}",
            requests[1]
        );
        assert!(requests[1].contains("\"type\":\"backup_setting\""));
        assert!(requests[1].contains("\"id\":\"set1\""));
        assert!(!requests[1].contains("enabled"), "req1: {}", requests[1]);
    }

    #[test]
    fn configure_validation_errors_surface_verbatim() {
        let server = script(vec![
            respond(
                "404 Not Found",
                r#"{"errors":[{"status":"404","title":"Not Found"}]}"#,
            ),
            respond(
                "422 Unprocessable Entity",
                r#"{"errors":[{"status":"422","title":"Unprocessable Entity","detail":"endpoint must be an http:// or https:// URL with a host and no path"}]}"#,
            ),
        ]);
        let flags = ConfigureBackup {
            instance: "i1".into(),
            endpoint: "ftp://nope".into(),
            bucket: "bucket".into(),
            prefix: None,
            access_key_id: "KEY".into(),
            retention: None,
            enabled: None,
        };
        let err = backups_configure(&client(&server.base_url), &flags, Output::Table).unwrap_err();
        assert!(
            err.to_string()
                .contains("endpoint must be an http:// or https:// URL with a host and no path"),
            "err: {err}"
        );
    }

    #[test]
    fn configure_scope_failures_pass_through_not_read_as_not_configured() {
        let server = script(vec![respond(
            "403 Forbidden",
            r#"{"errors":[{"status":"403","title":"Forbidden","detail":"token lacks the backups:write scope"}]}"#,
        )]);
        let flags = ConfigureBackup {
            instance: "i1".into(),
            endpoint: "https://e.example".into(),
            bucket: "bucket".into(),
            prefix: None,
            access_key_id: "KEY".into(),
            retention: None,
            enabled: None,
        };
        let err = backups_configure(&client(&server.base_url), &flags, Output::Table).unwrap_err();
        assert_eq!(
            err.to_string(),
            "403 Forbidden: token lacks the backups:write scope"
        );
    }

    #[test]
    fn status_rides_the_limit_page_and_renders_both_reads() {
        let server = script(vec![
            envelope(json!({"data": {"type": "instance", "id": "i1", "attributes": {}}})),
            envelope(json!({"data": setting_row()})),
            envelope(json!({"data": [succeeded_run()]})),
        ]);
        let rendered = backups_status(&client(&server.base_url), "i1", Output::Table).unwrap();
        assert!(
            rendered.contains("bucket         fluxvale-kavita"),
            "rendered:\n{rendered}"
        );
        assert!(
            rendered.contains("latest run     manual, succeeded"),
            "rendered:\n{rendered}"
        );

        let requests = captured_requests(&server);
        assert_eq!(requests.len(), 3, "three reads: instance, setting, runs");
        assert!(
            requests[0].starts_with("get /api/v1/instances/i1 http/1.1"),
            "req0: {}",
            requests[0]
        );
        assert!(
            requests[1].starts_with("get /api/v1/instances/i1/backup-setting http/1.1"),
            "req1: {}",
            requests[1]
        );
        // limit is REQUIRED on the wire — the route 400s without it.
        assert!(
            requests[2].starts_with("get /api/v1/instances/i1/backup-runs?limit=1 http/1.1"),
            "req2: {}",
            requests[2]
        );
    }

    #[test]
    fn status_unconfigured_vs_foreign_instance() {
        // Unconfigured (the instance IS the caller's): the sentence,
        // after the instance read passed.
        let server = script(vec![
            envelope(json!({"data": {"type": "instance", "id": "i1", "attributes": {}}})),
            respond(
                "404 Not Found",
                r#"{"errors":[{"status":"404","title":"Not Found"}]}"#,
            ),
            envelope(json!({"data": []})),
        ]);
        let rendered = backups_status(&client(&server.base_url), "i1", Output::Table).unwrap();
        assert_eq!(
            rendered,
            "backups are not configured for this instance\nno backup runs yet"
        );

        // Foreign instance: the INSTANCE read 404s — the friendly
        // line, and nothing else is read (the runs index would have
        // answered an empty 200 for a foreign id; the instance get is
        // what names it).
        let server = script(vec![respond(
            "404 Not Found",
            r#"{"errors":[{"status":"404","title":"Not Found"}]}"#,
        )]);
        let err = backups_status(&client(&server.base_url), "i9", Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "no such instance (or it's not yours)");
        assert_eq!(
            captured_requests(&server).len(),
            1,
            "stop after the instance read"
        );
    }

    #[test]
    fn run_posts_bodyless_and_prints_the_row() {
        let server = script(vec![respond(
            "201 Created",
            r#"{"kind":"manual","status":"running","instance_id":"i1","started_at":"2026-11-04T23:59:00Z"}"#,
        )]);
        let rendered = backups_run(&client(&server.base_url), "i1", Output::Table).unwrap();
        assert!(
            rendered.contains("status    running"),
            "rendered:\n{rendered}"
        );

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
    }

    #[test]
    fn run_refusals_surface_the_operations_own_words() {
        let server = script(vec![respond(
            "400 Bad Request",
            r#"{"errors":[{"detail":"backups are not configured for this instance"}]}"#,
        )]);
        let err = backups_run(&client(&server.base_url), "i1", Output::Table).unwrap_err();
        assert!(
            err.to_string()
                .contains("backups are not configured for this instance"),
            "err: {err}"
        );
    }

    #[test]
    fn run_404_reads_the_friendly_instance_line() {
        let server = script(vec![respond(
            "404 Not Found",
            r#"{"errors":[{"status":"404","title":"Not Found"}]}"#,
        )]);
        let err = backups_run(&client(&server.base_url), "i9", Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "no such instance (or it's not yours)");
    }

    #[test]
    fn restore_without_confirm_sends_nothing_and_prints_the_rerun_command() {
        // A listener nobody answers: if anything were sent, the call
        // would hang or fail with transport noise — and the accept
        // probe after the call proves zero connections arrived.
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let err = backups_restore(
            &client(&format!("http://{addr}")),
            "i1",
            "r9",
            false,
            Output::Table,
        )
        .unwrap_err();
        let text = err.to_string();
        assert!(
            text.contains("the current volume state is OVERWRITTEN"),
            "text: {text}"
        );
        assert!(text.contains("nothing was sent"), "text: {text}");
        assert!(
            text.contains("fluxvale backups restore i1 --from r9 --confirm"),
            "text: {text}"
        );

        listener.set_nonblocking(true).unwrap();
        assert!(
            matches!(listener.accept(), Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock),
            "no request may go out without --confirm"
        );
    }

    #[test]
    fn restore_with_confirm_posts_the_restore() {
        let server = script(vec![respond(
            "201 Created",
            r#"{"kind":"restore","status":"running","instance_id":"i1","restored_from":"running"}"#,
        )]);
        let rendered =
            backups_restore(&client(&server.base_url), "i1", "r9", true, Output::Table).unwrap();
        assert!(
            rendered.contains("kind           restore"),
            "rendered:\n{rendered}"
        );
        assert!(
            rendered.contains("restored from  running"),
            "rendered:\n{rendered}"
        );
        assert!(
            rendered.contains("status         running"),
            "rendered:\n{rendered}"
        );

        let requests = captured_requests(&server);
        assert!(
            requests[0].starts_with("post /api/v1/instances/i1/backup-runs/r9/restore http/1.1"),
            "req0: {}",
            requests[0]
        );
    }

    #[test]
    fn restore_refusals_surface_the_fences_words() {
        let server = script(vec![respond(
            "400 Bad Request",
            r#"{"errors":[{"detail":"is not the latest successful backup — restore targets the latest one"}]}"#,
        )]);
        let err = backups_restore(&client(&server.base_url), "i1", "r8", true, Output::Table)
            .unwrap_err();
        assert!(
            err.to_string()
                .contains("not the latest successful backup — restore targets the latest one"),
            "err: {err}"
        );
    }

    #[test]
    fn restore_refuses_route_hijacking_ids() {
        let client = client("http://127.0.0.1:1");
        let err = backups_restore(&client, "i1", "a/b", true, Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "invalid backup run id: a/b");
        let err = backups_restore(&client, "../other", "r9", true, Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "invalid instance id: ../other");
    }

    #[test]
    fn attach_posts_the_pairing_body_and_renders_the_route() {
        let server = script(vec![respond(
            "201 Created",
            r#"{"gateway_id":"g1","instance_id":"i1","route_key":"8443"}"#,
        )]);
        let rendered = access_attach(&client(&server.base_url), "g1", "i1", Output::Table).unwrap();
        assert!(
            rendered.contains("route key  8443"),
            "rendered:\n{rendered}"
        );

        let requests = captured_requests(&server);
        assert!(
            requests[0].starts_with("post /api/v1/access-gateways/g1/attachments http/1.1"),
            "req0: {}",
            requests[0]
        );
        assert!(requests[0].contains("content-type: application/vnd.api+json"));
        assert!(
            requests[0].contains("{\"instance_id\":\"i1\"}"),
            "req0: {}",
            requests[0]
        );
    }

    #[test]
    fn attach_refusals_surface_the_operations_own_words() {
        let server = script(vec![respond(
            "400 Bad Request",
            r#"{"errors":[{"detail":"the instance is not private — attach needs a private instance"}]}"#,
        )]);
        let err = access_attach(&client(&server.base_url), "g1", "i1", Output::Table).unwrap_err();
        assert!(
            err.to_string()
                .contains("the instance is not private — attach needs a private instance"),
            "err: {err}"
        );
    }

    #[test]
    fn pairing_404s_stay_honest_about_which_side_missed() {
        let server = script(vec![respond(
            "404 Not Found",
            r#"{"errors":[{"status":"404","title":"Not Found"}]}"#,
        )]);
        let err = access_attach(&client(&server.base_url), "g9", "i9", Output::Table).unwrap_err();
        assert_eq!(
            err.to_string(),
            "no such gateway or instance (or it's not yours)"
        );

        let server = script(vec![respond(
            "404 Not Found",
            r#"{"errors":[{"status":"404","title":"Not Found"}]}"#,
        )]);
        let err = access_detach(&client(&server.base_url), "g9", "i9", Output::Table).unwrap_err();
        assert_eq!(
            err.to_string(),
            "no such gateway or instance (or it's not yours)"
        );
    }

    #[test]
    fn detach_deletes_and_reads_a_plain_line() {
        let server = script(vec![respond("200 OK", r#"{"success":true}"#)]);
        let rendered = access_detach(&client(&server.base_url), "g1", "i1", Output::Table).unwrap();
        assert_eq!(rendered, "detached");

        let requests = captured_requests(&server);
        assert!(
            requests[0].starts_with("delete /api/v1/access-gateways/g1/attachments/i1 http/1.1"),
            "req0: {}",
            requests[0]
        );

        // JSON mode prints the wire answer verbatim.
        let server = script(vec![respond("200 OK", r#"{"success":true}"#)]);
        let rendered = access_detach(&client(&server.base_url), "g1", "i1", Output::Json).unwrap();
        assert_eq!(rendered, "{\n  \"success\": true\n}");
    }

    #[test]
    fn resume_patches_the_envelope_body_and_renders_the_row() {
        let server = script(vec![envelope(json!({
            "data": {"type": "access_gateway", "id": "g1", "attributes": {
                "id": "g1", "hostname": "fv-abc123", "state": "provisioning",
                "status_message": null, "monthly_cents": 500
            }}
        }))]);
        let rendered = access_resume(&client(&server.base_url), "g1", Output::Table).unwrap();
        assert!(
            rendered.contains("state           provisioning"),
            "rendered:\n{rendered}"
        );
        assert!(
            rendered.contains("monthly         $5.00"),
            "rendered:\n{rendered}"
        );

        let requests = captured_requests(&server);
        assert!(
            requests[0].starts_with("patch /api/v1/access-gateways/g1/resume http/1.1"),
            "req0: {}",
            requests[0]
        );
        // serde_json's default map sorts keys — the body's three keys
        // ride in that order.
        assert!(
            requests[0].contains(
                "{\"data\":{\"attributes\":{},\"id\":\"g1\",\"type\":\"access_gateway\"}}"
            ),
            "req0: {}",
            requests[0]
        );
    }

    #[test]
    fn resume_404_reads_the_friendly_gateway_line() {
        let server = script(vec![respond(
            "404 Not Found",
            r#"{"errors":[{"status":"404","title":"Not Found"}]}"#,
        )]);
        let err = access_resume(&client(&server.base_url), "g9", Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "no such gateway (or it's not yours)");
    }

    #[test]
    fn access_status_404_is_the_no_gateway_line() {
        let server = script(vec![respond(
            "404 Not Found",
            r#"{"errors":[{"status":"404","title":"Not Found"}]}"#,
        )]);
        let err = access_status(&client(&server.base_url), "org1", Output::Table).unwrap_err();
        assert_eq!(
            err.to_string(),
            "no gateway for this organization (or you're not a member)"
        );
    }

    #[test]
    fn access_status_renders_the_gateway_over_the_wire() {
        let server = script(vec![envelope(json!({
            "data": {"type": "access_gateway", "id": "g1", "attributes": {
                "id": "g1", "organization_id": "org1",
                "hostname": "fv-abc123", "tailnet_domain": "example.ts.net",
                "provider": "tailscale", "state": "active",
                "status_message": "Connected", "monthly_cents": 500,
                "provisioned_at": "2026-11-04T21:00:00Z"
            }}
        }))]);
        let rendered = access_status(&client(&server.base_url), "org1", Output::Table).unwrap();
        assert!(
            rendered.contains("hostname        fv-abc123"),
            "rendered:\n{rendered}"
        );
        assert!(
            rendered.contains("state           active"),
            "rendered:\n{rendered}"
        );
        assert!(
            rendered.contains("monthly         $5.00"),
            "rendered:\n{rendered}"
        );
        let requests = captured_requests(&server);
        assert!(
            requests[0].starts_with("get /api/v1/organizations/org1/access-gateway http/1.1"),
            "req0: {}",
            requests[0]
        );
    }

    #[test]
    fn gateway_create_is_the_panels_flow_not_the_clis() {
        let err = access_create_unavailable().unwrap_err();
        assert!(err.to_string().contains("Tailscale auth key"), "err: {err}");
        assert!(err.to_string().contains("panel"), "err: {err}");
    }

    #[test]
    fn pairing_ids_refuse_route_hijacking() {
        let client = client("http://127.0.0.1:1");
        let err = access_attach(&client, "g/1", "i1", Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "invalid gateway id: g/1");
        let err = access_detach(&client, "g1", "i 1", Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "invalid instance id: i 1");
        let err = access_resume(&client, "?g=", Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "invalid gateway id: ?g=");
        let err = access_status(&client, "../org", Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "invalid organization id: ../org");
    }

    // ---- the instance lifecycle (T5): the app → versions → create →
    // deploy sequence, the verbs, the destroy gate.

    fn app_row(slug: &str, app_id: &str) -> serde_json::Value {
        json!({
            "type": "app", "id": app_id,
            "attributes": {"id": app_id, "name": "Forgejo", "slug": slug, "file_access": false}
        })
    }

    fn version_row(version_id: &str, number: &str) -> serde_json::Value {
        json!({
            "type": "app_version", "id": version_id,
            "attributes": {
                "id": version_id, "app_id": "app1", "version": number,
                "image": &format!("ghcr.io/fluxvale/apps/forgejo:{number}"),
                "port": 3000, "default_cpu_cores": "0.5",
                "default_memory_mb": 512, "default_storage_gb": 1
            }
        })
    }

    fn instance_row(id: &str, status: &str) -> serde_json::Value {
        json!({
            "type": "instance", "id": id,
            "attributes": {
                "id": id, "name": "my forgejo", "slug": "my-forgejo-a1", "namespace": &format!("fluxvale-app-{id}"),
                "status": status, "exposure": "public", "always_on": false,
                "image": "ghcr.io/fluxvale/apps/forgejo:1.2", "port": 3000,
                "cpu_cores": "0.5", "memory_mb": 512, "storage_gb": 1,
                "healthcheck_path": "/health", "storage_mount_path": "/data",
                "file_access": false, "deployed_at": null
            }
        })
    }

    fn deploy_flags() -> DeployFlags {
        DeployFlags {
            app: "forgejo".into(),
            name: Some("my forgejo".into()),
            cpu: None,
            memory_mb: None,
            storage_gb: None,
            version: None,
        }
    }

    #[test]
    fn deploy_walks_app_versions_create_deploy_in_order() {
        let server = script(vec![
            envelope(json!({"data": app_row("forgejo", "app1")})),
            envelope(json!({"data": [version_row("v2", "1.2"), version_row("v1", "1.0")]})),
            respond(
                "201 Created",
                &json!({"data": instance_row("i1", "pending")}).to_string(),
            ),
            respond(
                "200 OK",
                &json!({"data": instance_row("i1", "deploying")}).to_string(),
            ),
        ]);
        let rendered =
            instances_deploy(&client(&server.base_url), &deploy_flags(), Output::Table).unwrap();
        assert!(
            rendered.contains("status        deploying"),
            "rendered:\n{rendered}"
        );
        assert!(
            rendered.ends_with("deploying forgejo 1.2 — watch with: fluxvale instances status i1"),
            "rendered:\n{rendered}"
        );

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
        // The create body: the newest version (the wire's own order),
        // the given name, NO env_vars (the wire refuses it).
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
        assert!(
            !requests[2].contains("env_vars"),
            "env_vars never rides: {}",
            requests[2]
        );
        assert!(
            !requests[2].contains("cpu_cores"),
            "unset flags stay out — catalog defaults apply: {}",
            requests[2]
        );
        // The deploy body: the id + empty attributes.
        assert!(
            requests[3]
                .contains("{\"data\":{\"attributes\":{},\"id\":\"i1\",\"type\":\"instance\"}}"),
            "req3: {}",
            requests[3]
        );
    }

    #[test]
    fn deploy_carries_only_the_given_resource_flags() {
        let server = script(vec![
            envelope(json!({"data": app_row("forgejo", "app1")})),
            envelope(json!({"data": [version_row("v2", "1.2")]})),
            respond(
                "201 Created",
                &json!({"data": instance_row("i1", "pending")}).to_string(),
            ),
            respond(
                "200 OK",
                &json!({"data": instance_row("i1", "deploying")}).to_string(),
            ),
        ]);
        let flags = DeployFlags {
            cpu: Some("1.5".into()),
            memory_mb: Some(1024),
            storage_gb: Some(5),
            name: None,
            ..deploy_flags()
        };
        instances_deploy(&client(&server.base_url), &flags, Output::Json).unwrap();
        let create = &captured_requests(&server)[2];
        assert!(create.contains("\"cpu_cores\":\"1.5\""), "create: {create}");
        assert!(create.contains("\"memory_mb\":1024"), "create: {create}");
        assert!(create.contains("\"storage_gb\":5"), "create: {create}");
        assert!(!create.contains("\"name\""), "create: {create}");
    }

    #[test]
    fn deploy_with_a_version_flag_takes_exactly_that_id() {
        let server = script(vec![
            envelope(json!({"data": app_row("forgejo", "app1")})),
            envelope(json!({"data": [version_row("v2", "1.2"), version_row("v1", "1.0")]})),
            respond(
                "201 Created",
                &json!({"data": instance_row("i1", "pending")}).to_string(),
            ),
            respond(
                "200 OK",
                &json!({"data": instance_row("i1", "deploying")}).to_string(),
            ),
        ]);
        let flags = DeployFlags {
            version: Some("v1".into()),
            ..deploy_flags()
        };
        let rendered = instances_deploy(&client(&server.base_url), &flags, Output::Table).unwrap();
        assert!(
            rendered.contains("deploying forgejo 1.0 —"),
            "rendered:\n{rendered}"
        );
        let create = &captured_requests(&server)[2];
        assert!(
            create.contains("\"app_version_id\":\"v1\""),
            "create: {create}"
        );
    }

    #[test]
    fn deploy_refuses_a_foreign_version_without_creating() {
        let server = script(vec![
            envelope(json!({"data": app_row("forgejo", "app1")})),
            envelope(json!({"data": [version_row("v2", "1.2")]})),
        ]);
        let flags = DeployFlags {
            version: Some("other-apps-version".into()),
            ..deploy_flags()
        };
        let err = instances_deploy(&client(&server.base_url), &flags, Output::Table).unwrap_err();
        let text = err.to_string();
        assert!(
            text.contains("version other-apps-version is not a version of forgejo"),
            "err: {err}"
        );
        assert!(text.contains("v2"), "the choices ride the error: {err}");
        assert_eq!(captured_requests(&server).len(), 2, "no create went out");
    }

    #[test]
    fn deploy_refuses_an_app_with_no_published_versions() {
        let server = script(vec![
            envelope(json!({"data": app_row("forgejo", "app1")})),
            envelope(json!({"data": []})),
        ]);
        let err = instances_deploy(&client(&server.base_url), &deploy_flags(), Output::Table)
            .unwrap_err();
        assert!(
            err.to_string()
                .contains("forgejo has no published versions"),
            "err: {err}"
        );
        assert_eq!(captured_requests(&server).len(), 2, "no create went out");
    }

    #[test]
    fn deploy_funded_gate_403_surfaces_verbatim() {
        let server = script(vec![
            envelope(json!({"data": app_row("forgejo", "app1")})),
            envelope(json!({"data": [version_row("v2", "1.2")]})),
            respond(
                "403 Forbidden",
                r#"{"errors":[{"status":"403","title":"Forbidden","detail":"the org wallet needs funds — top up at /billing/topup"}]}"#,
            ),
        ]);
        let err = instances_deploy(&client(&server.base_url), &deploy_flags(), Output::Table)
            .unwrap_err();
        assert!(
            err.to_string()
                .contains("403 Forbidden: the org wallet needs funds — top up at /billing/topup"),
            "err: {err}"
        );
    }

    #[test]
    fn deploy_app_404_reads_the_friendly_line() {
        let server = script(vec![respond(
            "404 Not Found",
            r#"{"errors":[{"status":"404","title":"Not Found"}]}"#,
        )]);
        let err = instances_deploy(&client(&server.base_url), &deploy_flags(), Output::Table)
            .unwrap_err();
        assert_eq!(err.to_string(), "no such app (or it's not yours)");
    }

    #[test]
    fn stop_and_start_patch_the_verbs_and_print_the_transition() {
        let server = script(vec![respond(
            "200 OK",
            &json!({"data": instance_row("i1", "stopped")}).to_string(),
        )]);
        let rendered = instances_stop(&client(&server.base_url), "i1", Output::Table).unwrap();
        assert!(
            rendered.contains("status  stopped"),
            "rendered:\n{rendered}"
        );
        assert!(
            rendered.ends_with("Stopped — your data is kept safe; start it again anytime."),
            "rendered:\n{rendered}"
        );
        let requests = captured_requests(&server);
        assert!(
            requests[0].starts_with("patch /api/v1/instances/i1/stop http/1.1"),
            "req0: {}",
            requests[0]
        );
        assert!(
            requests[0]
                .contains("{\"data\":{\"attributes\":{},\"id\":\"i1\",\"type\":\"instance\"}}"),
            "req0: {}",
            requests[0]
        );

        let server = script(vec![respond(
            "200 OK",
            &json!({"data": instance_row("i1", "starting")}).to_string(),
        )]);
        let rendered = instances_start(&client(&server.base_url), "i1", Output::Table).unwrap();
        assert!(
            rendered.contains("status  starting"),
            "rendered:\n{rendered}"
        );
        let requests = captured_requests(&server);
        assert!(
            requests[0].starts_with("patch /api/v1/instances/i1/start http/1.1"),
            "req0: {}",
            requests[0]
        );
    }

    #[test]
    fn lifecycle_verbs_404_read_the_friendly_instance_line() {
        for verb in ["stop", "start"] {
            let server = script(vec![respond(
                "404 Not Found",
                r#"{"errors":[{"status":"404","title":"Not Found"}]}"#,
            )]);
            let err = match verb {
                "stop" => {
                    instances_stop(&client(&server.base_url), "i9", Output::Table).unwrap_err()
                }
                _ => instances_start(&client(&server.base_url), "i9", Output::Table).unwrap_err(),
            };
            assert_eq!(err.to_string(), "no such instance (or it's not yours)");
        }
    }

    #[test]
    fn destroy_without_confirm_sends_nothing_and_prints_the_rerun_command() {
        // A listener nobody answers: anything sent would hang or fail
        // with transport noise — the accept probe after the call
        // proves zero connections arrived (the restore gate's shape).
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let err = instances_destroy(
            &client(&format!("http://{addr}")),
            "i1",
            false,
            Output::Table,
        )
        .unwrap_err();
        let text = err.to_string();
        assert!(
            text.contains("destroy instance i1 — all data on it is deleted"),
            "text: {text}"
        );
        assert!(text.contains("nothing was sent"), "text: {text}");
        assert!(
            text.contains("fluxvale instances destroy i1 --confirm"),
            "text: {text}"
        );

        listener.set_nonblocking(true).unwrap();
        assert!(
            matches!(listener.accept(), Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock),
            "no request may go out without --confirm"
        );
    }

    #[test]
    fn destroy_with_confirm_deletes_and_prints_the_server_words() {
        let server = script(vec![respond(
            "200 OK",
            r#"{"id":"i1","name":"my forgejo","slug":"my-forgejo-a1","status":"deleting"}"#,
        )]);
        let rendered =
            instances_destroy(&client(&server.base_url), "i1", true, Output::Table).unwrap();
        assert_eq!(
            rendered,
            "id      i1\n\
             name    my forgejo\n\
             status  deleting\n\
             Deleting — cleaning up your app and its data."
        );
        let requests = captured_requests(&server);
        assert!(
            requests[0].starts_with("delete /api/v1/instances/i1 http/1.1"),
            "req0: {}",
            requests[0]
        );

        // JSON prints the wire answer verbatim.
        let server = script(vec![respond(
            "200 OK",
            r#"{"id":"i1","status":"deleting"}"#,
        )]);
        let rendered =
            instances_destroy(&client(&server.base_url), "i1", true, Output::Json).unwrap();
        assert_eq!(
            rendered,
            "{\n  \"id\": \"i1\",\n  \"status\": \"deleting\"\n}"
        );
    }

    #[test]
    fn destroy_404_reads_the_friendly_instance_line() {
        let server = script(vec![respond(
            "404 Not Found",
            r#"{"errors":[{"status":"404","title":"Not Found"}]}"#,
        )]);
        let err =
            instances_destroy(&client(&server.base_url), "i9", true, Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "no such instance (or it's not yours)");
    }

    #[test]
    fn lifecycle_ids_refuse_route_hijacking() {
        let client = client("http://127.0.0.1:1");
        let flags = DeployFlags {
            app: "a/b".into(),
            ..deploy_flags()
        };
        let err = instances_deploy(&client, &flags, Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "invalid app slug: a/b");
        let err = instances_stop(&client, "a/b", Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "invalid instance id: a/b");
        let err = instances_start(&client, "../other", Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "invalid instance id: ../other");
        let err = instances_destroy(&client, "a b", true, Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "invalid instance id: a b");
    }
}
