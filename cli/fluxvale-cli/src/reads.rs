//! The read commands (T4 of #362): whoami, apps, instances, wallet,
//! topup. Thin clients over GET routes — every fact comes from the
//! API; formatting is local presentation only (ADR-0019 Am. 3).
//! Write commands stay out (T6); device-flow login is T5.

use crate::api::jsonapi::{Document, Resource};
use crate::api::{ApiClient, ApiError};
use crate::cli::Output;
use crate::config::{self, Config};
use crate::human;
use crate::render::{Detail, Rows, cell, yes_no};
use crate::token::{TokenLocation, TokenStore};
use serde_json::{Value, json};

/// The client for a read command: token from the store (OS keychain,
/// 0600-file fallback), its location along for `whoami`'s line.
pub fn read_client(config: &Config) -> anyhow::Result<(ApiClient, TokenLocation)> {
    let store = TokenStore::at(TokenStore::default_dir()?);
    let host = config::host_from_base_url(&config.base_url);
    let Some((token, location)) = store.load(&host)? else {
        anyhow::bail!("Not signed in. Run `fluxvale auth login` to sign in.")
    };
    Ok((ApiClient::new(&config.base_url, token), location))
}

/// The JSON:API resource-level `id` hoisted into the attrs map, so
/// `--output json` carries it (`jq .id`) and the CLI can feed its own
/// follow-up commands.
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

/// One URL path segment: the CLI interpolates these into request
/// paths, so `/ ? # %` (and dot segments) are refused up front —
/// they'd address a different route.
fn safe_segment(thing: &str, value: &str) -> anyhow::Result<()> {
    let bad = value.is_empty()
        || value.contains(['/', '?', '#', '%'])
        || value.contains("..")
        || value.chars().any(char::is_whitespace);
    if bad {
        anyhow::bail!("invalid {thing}: {value}");
    }
    Ok(())
}

/// `whoami` — GET /me. The HTTP route returns the user WITHOUT scopes
/// or organizations (those are MCP-only surfaces), so the scope answer
/// is the panel, not an invented field.
pub fn whoami(
    client: &ApiClient,
    location: TokenLocation,
    output: Output,
) -> anyhow::Result<String> {
    whoami_rendered(client.get("/me")?, location, output)
}

fn whoami_rendered(
    document: Document,
    location: TokenLocation,
    output: Output,
) -> anyhow::Result<String> {
    let resource = one_resource(document, "user")?;
    Ok(match output {
        Output::Table => {
            let email = resource
                .attributes
                .get("email")
                .and_then(Value::as_str)
                .unwrap_or("(no verified email)");
            let mut line = format!("signed in as {email} via {location}");
            // /me carries the role; surface it when it isn't the default.
            if resource
                .attributes
                .get("platform_role")
                .and_then(Value::as_str)
                == Some("admin")
            {
                line.push_str("\nplatform role: admin");
            }
            line
        }
        Output::Json => crate::render::to_pretty(&with_id(&resource)),
    })
}

/// `apps list` — the public catalog.
pub fn apps_list(client: &ApiClient, output: Output) -> anyhow::Result<String> {
    apps_list_rendered(client.get("/apps")?, output)
}

fn apps_list_rendered(document: Document, output: Output) -> anyhow::Result<String> {
    let mut rows = Rows::new(&["NAME", "SLUG"], "no apps in the catalog yet");
    for resource in document.resources() {
        let attrs = &resource.attributes;
        rows.push(
            vec![cell(attrs.get("name")), cell(attrs.get("slug"))],
            with_id(&resource),
        );
    }
    Ok(rows.render(output))
}

/// `apps show <slug>` — the catalog detail (the route's own fields).
pub fn apps_show(client: &ApiClient, slug: &str, output: Output) -> anyhow::Result<String> {
    safe_segment("app slug", slug)?;
    apps_show_rendered(get_or_404(client, &format!("/apps/{slug}"), "app")?, output)
}

fn apps_show_rendered(document: Document, output: Output) -> anyhow::Result<String> {
    let resource = one_resource(document, "app")?;
    let attrs = with_id(&resource);
    let mut detail = Detail::new(attrs.clone());
    detail.field("name", cell(attrs.get("name")));
    detail.field("slug", cell(attrs.get("slug")));
    detail.field("tagline", cell(attrs.get("tagline")));
    detail.field("description", cell(attrs.get("description")));
    detail.field("file access", yes_no(attrs.get("file_access")));
    detail.field("docs", cell(attrs.get("docs_url")));
    detail.field("source", cell(attrs.get("source_url")));
    detail.field("icon", cell(attrs.get("icon_url")));
    Ok(detail.render(output))
}

/// `instances list` — the actor's instances (name/slug/status/
/// always-on/deployed).
pub fn instances_list(client: &ApiClient, output: Output) -> anyhow::Result<String> {
    instances_rendered(client.get("/instances")?, output, false, now_secs())
}

/// `instances status` with no id — the same list, verbose (every field
/// the list route returns).
pub fn instances_status_all(client: &ApiClient, output: Output) -> anyhow::Result<String> {
    instances_rendered(client.get("/instances")?, output, true, now_secs())
}

fn instances_rendered(
    document: Document,
    output: Output,
    verbose: bool,
    now: i64,
) -> anyhow::Result<String> {
    let (headers, empty): (&[&str], &str) = if verbose {
        (
            &[
                "NAME",
                "SLUG",
                "NAMESPACE",
                "STATUS",
                "EXPOSURE",
                "ALWAYS-ON",
                "DEPLOYED",
                "ID",
            ],
            "no instances yet — create one in the panel",
        )
    } else {
        (
            &["NAME", "SLUG", "STATUS", "ALWAYS-ON", "DEPLOYED"],
            "no instances yet — create one in the panel",
        )
    };
    let mut rows = Rows::new(headers, empty);
    for resource in document.resources() {
        let attrs = &resource.attributes;
        let always_on = match attrs.get("always_on").and_then(Value::as_bool) {
            Some(true) => "yes".to_string(),
            Some(false) => "no".to_string(),
            None => "-".to_string(),
        };
        let deployed = human::relative(attrs.get("deployed_at").and_then(Value::as_str), now);
        let mut cells = match verbose {
            true => vec![
                cell(attrs.get("name")),
                cell(attrs.get("slug")),
                cell(attrs.get("namespace")),
                cell(attrs.get("status")),
                cell(attrs.get("exposure")),
                always_on,
                deployed,
            ],
            false => vec![
                cell(attrs.get("name")),
                cell(attrs.get("slug")),
                cell(attrs.get("status")),
                always_on,
                deployed,
            ],
        };
        // The resource id rides verbose tables — it is what
        // `instances status <id>` consumes next.
        if verbose {
            cells.push(resource.id.clone());
        }
        rows.push(cells, with_id(&resource));
    }
    Ok(rows.render(output))
}

/// `instances status <id>` — the detail route's fields plus the
/// plain-language status line.
pub fn instances_status(client: &ApiClient, id: &str, output: Output) -> anyhow::Result<String> {
    safe_segment("instance id", id)?;
    let document = get_or_404(client, &format!("/instances/{id}"), "instance")?;
    instances_status_rendered(document, output, now_secs())
}

fn instances_status_rendered(
    document: Document,
    output: Output,
    now: i64,
) -> anyhow::Result<String> {
    let resource = one_resource(document, "instance")?;
    let attrs = with_id(&resource);
    let mut detail = Detail::new(attrs.clone());
    detail.field("id", cell(attrs.get("id")));
    detail.field("name", cell(attrs.get("name")));
    detail.field("slug", cell(attrs.get("slug")));
    detail.field("status", cell(attrs.get("status")));
    detail.field("exposure", cell(attrs.get("exposure")));
    detail.field("always on", yes_no(attrs.get("always_on")));
    detail.field("image", cell(attrs.get("image")));
    detail.field("port", cell(attrs.get("port")));
    detail.field("cpu cores", cell(attrs.get("cpu_cores")));
    detail.field("memory (MB)", cell(attrs.get("memory_mb")));
    detail.field("storage (GB)", cell(attrs.get("storage_gb")));
    detail.field("storage mount", cell(attrs.get("storage_mount_path")));
    detail.field("healthcheck path", cell(attrs.get("healthcheck_path")));
    detail.field("file access", yes_no(attrs.get("file_access")));
    detail.field("deployed", deployed_cell(attrs.get("deployed_at"), now));
    detail.field("namespace", cell(attrs.get("namespace")));
    let mut rendered = detail.render(output);
    if output == Output::Table {
        let status = attrs.get("status").and_then(Value::as_str).unwrap_or("");
        rendered.push('\n');
        rendered.push_str(&status_line(status));
    }
    Ok(rendered)
}

/// The deployed timestamp reads relative with the raw stamp kept for
/// honesty ("3h ago (2026-11-04T12:34:56Z)"); "-" when never deployed.
fn deployed_cell(value: Option<&Value>, now: i64) -> String {
    let Some(raw) = value.and_then(Value::as_str) else {
        return "-".to_string();
    };
    let ago = human::relative(Some(raw), now);
    match ago.as_str() {
        "-" => raw.to_string(),
        stamp => format!("{stamp} ({raw})"),
    }
}

/// The plain-language status line — the client's presentation of the
/// server's user-facing status vocabulary (the page derives its copy
/// from the same atoms; `failure_reason` is not on the wire, so
/// `error` stays generic here).
pub fn status_line(status: &str) -> String {
    match status {
        "pending" => "Submitted — setup will begin shortly.",
        "deploying" => "Provisioning — setting up your app.",
        "starting" => "Starting it up.",
        "running" => "Running — your app is up.",
        "sleeping" => {
            "Sleeping — wakes automatically on the next visit; storage-only cost while it rests."
        }
        "restoring" => "Restoring — your app comes back the way you left it when it's done.",
        "stopped" => "Stopped — your data is kept safe; start it again anytime.",
        "error" => "Failed — something went wrong on our side; if it keeps happening, we're on it.",
        "deleting" => "Deleting — cleaning up your app and its data.",
        "lost" => "Lost — the app went missing on our side; billing has stopped. Set it up again or delete it.",
        other => return format!("status: {other}"),
    }
    .to_string()
}

/// The org id for wallet commands: the flag wins over the config file;
/// neither → where to set it. (The HTTP API has no org-list route and
/// no instance field exposes the org id, so the CLI can't discover it.)
pub fn resolve_org(config: &Config, flag: Option<&str>) -> anyhow::Result<String> {
    flag.or(config.organization_id.as_deref())
        .map(str::to_owned)
        .ok_or_else(|| {
            anyhow::anyhow!(
                "no organization id — pass --org <id>, or set organization_id in the \
                 config file"
            )
        })
}

/// `wallet balance` — GET /organizations/:id/wallet.
pub fn wallet_balance(client: &ApiClient, org_id: &str, output: Output) -> anyhow::Result<String> {
    safe_segment("organization id", org_id)?;
    wallet_balance_rendered(
        get_or_404(client, &format!("/organizations/{org_id}/wallet"), "wallet")?,
        output,
    )
}

fn wallet_balance_rendered(document: Document, output: Output) -> anyhow::Result<String> {
    let resource = one_resource(document, "wallet")?;
    let attrs = with_id(&resource);
    let mut detail = Detail::new(attrs.clone());
    detail.field("id", cell(attrs.get("id")));
    detail.field("organization", cell(attrs.get("organization_id")));
    detail.field("balance", money_cell(attrs.get("balance")));
    detail.field("paywall waived", yes_no(attrs.get("paywall_waived")));
    Ok(detail.render(output))
}

/// `wallet runway` — GET /organizations/:id/wallet/runway. The
/// projection answers a bare JSON object, not a JSON:API envelope.
pub fn wallet_runway(client: &ApiClient, org_id: &str, output: Output) -> anyhow::Result<String> {
    safe_segment("organization id", org_id)?;
    let map = client
        .get_json(&format!("/organizations/{org_id}/wallet/runway"))
        .map_err(|err| friendly_404(err, "wallet"))?;
    wallet_runway_rendered(map, output)
}

fn wallet_runway_rendered(map: Value, output: Output) -> anyhow::Result<String> {
    let mut detail = Detail::new(map.clone());
    detail.field("balance", money_cell(map.get("balance_cents")));
    detail.field(
        "burn",
        match map.get("burn_micro_cents_per_hour").and_then(Value::as_i64) {
            Some(micro_cents) => human::money_micro_per_hour(micro_cents),
            None => "-".to_string(),
        },
    );
    detail.field(
        "runway",
        human::runway_hours(map.get("runway_hours").unwrap_or(&Value::Null)),
    );
    Ok(detail.render(output))
}

/// Whole-cents cell: null (the aggregate's empty sum) reads "-".
fn money_cell(value: Option<&Value>) -> String {
    match value.and_then(Value::as_i64) {
        Some(cents) => human::money(cents),
        None => "-".to_string(),
    }
}

/// `topup` — the panel's top-up URL; `--open` hands it to the OS
/// launcher.
pub fn topup(base_url: &str, open: bool) -> anyhow::Result<String> {
    let url = topup_url(base_url);
    if open {
        open_url(&url)?;
    }
    Ok(url)
}

/// The config's canonical origin + the panel's live route
/// (`/billing/topup` in the platform router).
pub fn topup_url(base_url: &str) -> String {
    format!("{}/billing/topup", base_url.trim_end_matches('/'))
}

/// Hand the URL to the OS launcher. Launching a browser is inherently
/// environment-dependent — only the command choice and URL are
/// testable; the rest fails loudly with the manual fallback.
pub fn open_url(url: &str) -> anyhow::Result<()> {
    let mut command = open_command(url);
    let status = command.status().map_err(|err| {
        anyhow::anyhow!("couldn't launch a browser ({err}) — open {url} manually")
    })?;
    if !status.success() {
        anyhow::bail!("the OS launcher failed — open {url} manually");
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn open_command(url: &str) -> std::process::Command {
    let mut command = std::process::Command::new("open");
    command.arg(url);
    command
}

#[cfg(windows)]
fn open_command(url: &str) -> std::process::Command {
    // `start` is a cmd builtin, not an executable — and its FIRST
    // quoted argument is the window title, so the empty "" guards the
    // URL against being swallowed as one.
    let mut command = std::process::Command::new("cmd");
    command.args(["/C", "start", ""]);
    command.arg(url);
    command
}

#[cfg(not(any(target_os = "macos", windows)))]
fn open_command(url: &str) -> std::process::Command {
    let mut command = std::process::Command::new("xdg-open");
    command.arg(url);
    command
}

/// One resource or a loud error — a silently-empty document must not
/// render as an empty table.
fn one_resource(document: Document, type_name: &str) -> anyhow::Result<Resource> {
    let mut resources = document.resources();
    match resources.len() {
        1 => Ok(resources.remove(0)),
        0 => anyhow::bail!("the API returned no {type_name}"),
        _ => anyhow::bail!(
            "the API returned {} {type_name} resources, expected one",
            resources.len()
        ),
    }
}

/// GET with the 404 remapped to the thing's friendly line.
fn get_or_404(client: &ApiClient, path: &str, thing: &str) -> anyhow::Result<Document> {
    client.get(path).map_err(|err| friendly_404(err, thing))
}

/// 404 → "no such <thing> (or it's not yours)" — the API can't tell a
/// missing row from a foreign one, and neither should we.
fn friendly_404(err: ApiError, thing: &str) -> anyhow::Error {
    match err {
        ApiError::NotFound => anyhow::anyhow!("no such {thing} (or it's not yours)"),
        other => other.into(),
    }
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::{Read as _, Write as _};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    const NOW: i64 = 1793836800; // 2026-11-05T00:00:00Z

    fn document(value: serde_json::Value) -> Document {
        serde_json::from_value(value).unwrap()
    }

    // ---- fixture-render tests: the envelope -> the unwrap -> the render

    #[test]
    fn whoami_renders_the_signed_in_line() {
        let location = TokenLocation::Keychain;
        let line = whoami_rendered(
            document(json!({
                "data": {"type": "user", "id": "01H",
                         "attributes": {"email": "me@example.com",
                                        "platform_role": "user",
                                        "username": "me"}}
            })),
            location,
            Output::Table,
        )
        .unwrap();
        assert_eq!(line, "signed in as me@example.com via the OS keychain");
    }

    #[test]
    fn whoami_surfaces_the_admin_role_and_the_credentials_file_location() {
        let line = whoami_rendered(
            document(json!({
                "data": {"type": "user", "id": "01H",
                         "attributes": {"email": "me@example.com",
                                        "platform_role": "admin"}}
            })),
            TokenLocation::FallbackFile,
            Output::Table,
        )
        .unwrap();
        assert_eq!(
            line,
            "signed in as me@example.com via the credentials file\nplatform role: admin"
        );
    }

    #[test]
    fn whoami_json_is_the_raw_attrs() {
        let rendered = whoami_rendered(
            document(json!({
                "data": {"type": "user", "id": "01H",
                         "attributes": {"email": "me@example.com",
                                        "platform_role": "user"}}
            })),
            TokenLocation::Keychain,
            Output::Json,
        )
        .unwrap();
        let attrs: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(attrs["email"], "me@example.com");
        assert_eq!(attrs["platform_role"], "user");
    }

    #[test]
    fn whoami_copes_with_a_nil_email() {
        // A straggler account mid-#285 migration has no verified row.
        let line = whoami_rendered(
            document(json!({
                "data": {"type": "user", "id": "01H",
                         "attributes": {"email": null, "platform_role": "user"}}
            })),
            TokenLocation::Keychain,
            Output::Table,
        )
        .unwrap();
        assert_eq!(line, "signed in as (no verified email) via the OS keychain");
    }

    #[test]
    fn apps_list_renders_name_and_slug() {
        let rendered = apps_list_rendered(
            document(json!({
                "data": [
                    {"type": "app", "id": "1", "attributes": {"name": "WordPress", "slug": "wordpress"}},
                    {"type": "app", "id": "2", "attributes": {"name": "Kavita", "slug": "kavita"}}
                ]
            })),
            Output::Table,
        )
        .unwrap();
        assert_eq!(
            rendered,
            "NAME       SLUG\nWordPress  wordpress\nKavita     kavita"
        );
    }

    #[test]
    fn apps_list_json_is_raw_attrs_and_empty_reads_as_a_sentence() {
        let rendered = apps_list_rendered(
            document(json!({"data": [
                {"type": "app", "id": "1", "attributes": {"name": "WordPress", "slug": "wordpress"}}
            ]})),
            Output::Json,
        )
        .unwrap();
        let attrs: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(attrs[0]["slug"], "wordpress");

        let empty = apps_list_rendered(document(json!({"data": []})), Output::Table).unwrap();
        assert_eq!(empty, "no apps in the catalog yet");
    }

    #[test]
    fn apps_show_renders_the_route_fields() {
        let rendered = apps_show_rendered(
            document(json!({
                "data": {"type": "app", "id": "1", "attributes": {
                    "name": "WordPress", "slug": "wordpress", "tagline": "Blogging",
                    "description": "The classic.", "file_access": true,
                    "docs_url": "https://docs.example", "source_url": null,
                    "icon_url": "https://icon.example/w.png"}}
            })),
            Output::Table,
        )
        .unwrap();
        assert_eq!(
            rendered,
            "name         WordPress\n\
             slug         wordpress\n\
             tagline      Blogging\n\
             description  The classic.\n\
             file access  yes\n\
             docs         https://docs.example\n\
             source       -\n\
             icon         https://icon.example/w.png"
        );
    }

    #[test]
    fn instances_list_renders_relative_deployed() {
        let rendered = instances_rendered(
            document(json!({
                "data": [
                    {"type": "instance", "id": "i1", "attributes": {
                        "name": "web", "slug": "web-a1b2", "status": "running",
                        "always_on": true, "deployed_at": "2026-11-04T21:00:00Z"}},
                    {"type": "instance", "id": "i2", "attributes": {
                        "name": "db", "slug": "db-c3d4", "status": "stopped",
                        "always_on": false, "deployed_at": null}}
                ]
            })),
            Output::Table,
            false,
            NOW,
        )
        .unwrap();
        assert_eq!(
            rendered,
            "NAME  SLUG      STATUS   ALWAYS-ON  DEPLOYED\n\
             web   web-a1b2  running  yes        3h ago\n\
             db    db-c3d4   stopped  no         -"
        );
    }

    #[test]
    fn instances_list_verbose_adds_the_list_routes_other_fields() {
        let rendered = instances_rendered(
            document(json!({
                "data": [
                    {"type": "instance", "id": "i1", "attributes": {
                        "name": "web", "slug": "web-a1b2", "namespace": "fluxvale-app-i1",
                        "status": "running", "exposure": "public", "always_on": false,
                        "deployed_at": "2026-11-04T23:58:00Z"}}
                ]
            })),
            Output::Table,
            true,
            NOW,
        )
        .unwrap();
        assert_eq!(
            rendered,
            "NAME  SLUG      NAMESPACE        STATUS   EXPOSURE  ALWAYS-ON  DEPLOYED  ID\n\
             web   web-a1b2  fluxvale-app-i1  running  public    no         2m ago    i1"
        );
    }

    #[test]
    fn instances_list_json_is_raw_attrs() {
        let rendered = instances_rendered(
            document(json!({"data": [
                {"type": "instance", "id": "i1", "attributes": {"name": "web", "deployed_at": "2026-11-04T21:00:00Z"}}
            ]})),
            Output::Json,
            false,
            NOW,
        )
        .unwrap();
        let attrs: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        // The raw stamp rides; the derived "3h ago" cell does not.
        assert_eq!(attrs[0]["deployed_at"], "2026-11-04T21:00:00Z");
        assert_eq!(attrs[0]["name"], "web");
    }

    #[test]
    fn instances_status_renders_the_detail_and_the_status_line() {
        let rendered = instances_status_rendered(
            document(json!({
                "data": {"type": "instance", "id": "i1", "attributes": {
                    "name": "web", "slug": "web-a1b2", "namespace": "fluxvale-app-i1",
                    "status": "sleeping", "exposure": "private", "always_on": false,
                    "image": "ghcr.io/fluxvale/apps/wordpress:1.2", "port": 8080,
                    "cpu_cores": "0.5", "memory_mb": 512, "storage_gb": 1,
                    "storage_mount_path": "/data", "healthcheck_path": "/health",
                    "file_access": true, "deployed_at": "2026-11-04T21:00:00Z"}}
            })),
            Output::Table,
            NOW,
        )
        .unwrap();
        // The resource-level id renders (it is not an attribute).
        assert!(
            rendered.contains("id                i1"),
            "rendered:\n{rendered}"
        );
        assert!(
            rendered.contains("cpu cores         0.5"),
            "rendered:\n{rendered}"
        );
        assert!(
            rendered.contains("memory (MB)       512"),
            "rendered:\n{rendered}"
        );
        assert!(
            rendered.contains("storage (GB)      1"),
            "rendered:\n{rendered}"
        );
        assert!(rendered.contains("image             ghcr.io/fluxvale/apps/wordpress:1.2"));
        assert!(rendered.contains("exposure          private"));
        assert!(rendered.contains("deployed          3h ago (2026-11-04T21:00:00Z)"));
        assert!(
            rendered.ends_with("\nSleeping — wakes automatically on the next visit; storage-only cost while it rests."),
            "rendered:\n{rendered}"
        );
    }

    #[test]
    fn instances_status_json_is_raw_attrs_without_the_status_line() {
        let rendered = instances_status_rendered(
            document(json!({
                "data": {"type": "instance", "id": "i1", "attributes": {"status": "running"}}
            })),
            Output::Json,
            NOW,
        )
        .unwrap();
        let attrs: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(attrs["status"], "running");
        assert!(
            !rendered.contains("Running —"),
            "status line leaked: {rendered}"
        );
    }

    #[test]
    fn every_known_status_has_a_line() {
        // The wire enum's full set (types.rs InstanceAttributesStatus).
        for status in [
            "pending",
            "deploying",
            "starting",
            "running",
            "sleeping",
            "restoring",
            "stopped",
            "error",
            "deleting",
            "lost",
        ] {
            let line = status_line(status);
            assert!(!line.is_empty(), "{status} must render");
            assert_ne!(
                line,
                format!("status: {status}"),
                "{status} needs real copy"
            );
        }
        // An unknown future status degrades to the raw atom, not a crash.
        assert_eq!(status_line("hibernating"), "status: hibernating");
    }

    // ---- wallet

    #[test]
    fn wallet_balance_renders_money_and_waiver() {
        let rendered = wallet_balance_rendered(
            document(json!({
                "data": {"type": "wallet", "id": "w1", "attributes": {
                    "organization_id": "org1", "balance": 1900, "paywall_waived": false}}
            })),
            Output::Table,
        )
        .unwrap();
        assert_eq!(
            rendered,
            "id              w1\n\
             organization    org1\n\
             balance         $19.00\n\
             paywall waived  no"
        );
    }

    #[test]
    fn wallet_balance_json_is_raw_attrs_and_nil_balance_reads_a_dash() {
        let rendered = wallet_balance_rendered(
            document(json!({
                "data": {"type": "wallet", "id": "w1", "attributes": {
                    "organization_id": "org1", "balance": -250, "paywall_waived": true}}
            })),
            Output::Table,
        )
        .unwrap();
        assert!(
            rendered.contains("id              w1"),
            "rendered:\n{rendered}"
        );
        assert!(
            rendered.contains("balance         -$2.50"),
            "rendered:\n{rendered}"
        );
        assert!(
            rendered.contains("paywall waived  yes"),
            "rendered:\n{rendered}"
        );

        let nil = wallet_balance_rendered(
            document(json!({
                "data": {"type": "wallet", "id": "w1", "attributes": {
                    "organization_id": "org1", "balance": null, "paywall_waived": false}}
            })),
            Output::Table,
        )
        .unwrap();
        assert!(nil.contains("balance         -"), "rendered:\n{nil}");
    }

    #[test]
    fn wallet_runway_renders_the_projection() {
        let rendered = wallet_runway_rendered(
            json!({
                "balance_cents": 400, "burn_micro_cents_per_hour": 5016,
                "runway_hours": 79109.53
            }),
            Output::Table,
        )
        .unwrap();
        assert!(rendered.contains("balance  $4.00"), "rendered:\n{rendered}");
        assert!(
            rendered.contains("burn     $0.005/hr"),
            "rendered:\n{rendered}"
        );
        assert!(
            rendered.contains("runway   3296d 5h"),
            "rendered:\n{rendered}"
        );
    }

    #[test]
    fn wallet_runway_json_is_the_bare_map() {
        let rendered = wallet_runway_rendered(
            json!({
                "balance_cents": 400, "burn_micro_cents_per_hour": 0,
                "runway_hours": "infinity"
            }),
            Output::Json,
        )
        .unwrap();
        let map: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(
            map,
            json!({
                "balance_cents": 400, "burn_micro_cents_per_hour": 0,
                "runway_hours": "infinity"
            })
        );
    }

    #[test]
    fn wallet_runway_infinity_reads_the_no_burn_line() {
        assert_eq!(human::runway_hours(&json!("infinity")), "∞ (no burn)");
    }

    // ---- org resolution, topup

    #[test]
    fn org_id_resolution_flag_wins_over_config() {
        let config = Config {
            organization_id: Some("from-config".into()),
            ..Config::default()
        };
        assert_eq!(
            resolve_org(&config, Some("from-flag")).unwrap(),
            "from-flag"
        );
        assert_eq!(resolve_org(&config, None).unwrap(), "from-config");
    }

    #[test]
    fn org_id_resolution_without_either_explains_where_to_look() {
        let config = Config::default();
        let err = resolve_org(&config, None).unwrap_err();
        let message = err.to_string();
        assert!(message.contains("--org"), "message: {message}");
        assert!(message.contains("organization_id"), "message: {message}");
    }

    #[test]
    fn topup_url_joins_the_canonical_origin() {
        assert_eq!(
            topup_url("https://fluxvale.com"),
            "https://fluxvale.com/billing/topup"
        );
        // A trailing slash must not double.
        assert_eq!(
            topup_url("https://app.fluxvale.lvh.me/"),
            "https://app.fluxvale.lvh.me/billing/topup"
        );
        assert_eq!(
            topup_url("http://127.0.0.1:4000"),
            "http://127.0.0.1:4000/billing/topup"
        );
    }

    // ---- mock-server end-to-end: the Authorization header rides, the
    // right path goes out. The scaffold's one-shot TcpListener pattern.

    struct OneShot {
        base_url: String,
        captured_head: Arc<Mutex<String>>,
    }

    fn serve(response: &str) -> OneShot {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let captured_head = Arc::new(Mutex::new(String::new()));
        let captured = captured_head.clone();
        let response = response.to_string();
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut head = String::new();
            let mut buf = [0u8; 4096];
            while !head.contains("\r\n\r\n") {
                let read = stream.read(&mut buf).unwrap();
                if read == 0 {
                    break;
                }
                head.push_str(&String::from_utf8_lossy(&buf[..read]));
            }
            *captured.lock().unwrap() = head;
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.flush();
        });
        OneShot {
            base_url: format!("http://{addr}"),
            captured_head,
        }
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

    #[test]
    fn whoami_rides_the_bearer_token_to_me() {
        let server = serve(&envelope(json!({
            "data": {"type": "user", "id": "01H",
                     "attributes": {"email": "me@example.com", "platform_role": "user"}}
        })));
        let rendered = whoami(
            &client(&server.base_url),
            TokenLocation::Keychain,
            Output::Table,
        )
        .unwrap();
        assert!(rendered.contains("me@example.com"), "rendered: {rendered}");
        let head = server.captured_head.lock().unwrap().to_lowercase();
        assert!(
            head.starts_with("get /api/v1/me http/1.1"),
            "request line: {head}"
        );
        assert!(
            head.contains("authorization: bearer fvpat_testtoken"),
            "head: {head}"
        );
    }

    #[test]
    fn instances_list_hits_the_collection_with_auth() {
        let server = serve(&envelope(json!({"data": [
            {"type": "instance", "id": "i1", "attributes": {
                "name": "web", "slug": "web-a1b2", "status": "running",
                "always_on": true, "deployed_at": "2026-11-04T21:00:00Z"}}
        ]})));
        let rendered = instances_list(&client(&server.base_url), Output::Table).unwrap();
        assert!(rendered.contains("web-a1b2"), "rendered: {rendered}");
        let head = server.captured_head.lock().unwrap().to_lowercase();
        assert!(
            head.starts_with("get /api/v1/instances http/1.1"),
            "request line: {head}"
        );
        assert!(
            head.contains("authorization: bearer fvpat_testtoken"),
            "head: {head}"
        );
    }

    #[test]
    fn wallet_balance_addresses_the_org_wallet() {
        let server = serve(&envelope(json!({
            "data": {"type": "wallet", "id": "w1", "attributes": {
                "organization_id": "org1", "balance": 1900, "paywall_waived": false}}
        })));
        let rendered = wallet_balance(&client(&server.base_url), "org1", Output::Table).unwrap();
        assert!(rendered.contains("$19.00"), "rendered: {rendered}");
        let head = server.captured_head.lock().unwrap().to_lowercase();
        assert!(
            head.starts_with("get /api/v1/organizations/org1/wallet http/1.1"),
            "request line: {head}"
        );
    }

    #[test]
    fn wallet_runway_addresses_the_runway_projection() {
        let server = serve(&respond(
            "200 OK",
            r#"{"balance_cents":400,"burn_micro_cents_per_hour":0,"runway_hours":"infinity"}"#,
        ));
        let rendered = wallet_runway(&client(&server.base_url), "org1", Output::Table).unwrap();
        assert!(rendered.contains("∞ (no burn)"), "rendered: {rendered}");
        let head = server.captured_head.lock().unwrap().to_lowercase();
        assert!(
            head.starts_with("get /api/v1/organizations/org1/wallet/runway http/1.1"),
            "request line: {head}"
        );
    }

    #[test]
    fn apps_show_404_reads_the_friendly_line() {
        let server = serve(&respond(
            "404 Not Found",
            r#"{"errors":[{"status":"404","title":"Not Found"}]}"#,
        ));
        let err = apps_show(&client(&server.base_url), "nope", Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "no such app (or it's not yours)");
    }

    #[test]
    fn instances_status_404_reads_the_friendly_line() {
        let server = serve(&respond(
            "404 Not Found",
            r#"{"errors":[{"status":"404","title":"Not Found"}]}"#,
        ));
        let err = instances_status(&client(&server.base_url), "i9", Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "no such instance (or it's not yours)");
    }

    #[test]
    fn unauthorized_passes_the_scaffold_message_through() {
        let server = serve(&respond(
            "401 Unauthorized",
            r#"{"errors":[{"status":"401","title":"Unauthorized"}]}"#,
        ));
        let err = whoami(
            &client(&server.base_url),
            TokenLocation::Keychain,
            Output::Table,
        )
        .unwrap_err();
        assert_eq!(
            err.to_string(),
            "not signed in or token revoked (fluxvale auth login)"
        );
    }

    #[test]
    fn single_resource_document_with_wrong_arity_is_loud() {
        let err = one_resource(document(json!({"data": []})), "user").unwrap_err();
        assert_eq!(err.to_string(), "the API returned no user");

        let err = one_resource(
            document(json!({"data": [
                {"type": "user", "id": "1", "attributes": {}},
                {"type": "user", "id": "2", "attributes": {}}
            ]})),
            "user",
        )
        .unwrap_err();
        assert_eq!(
            err.to_string(),
            "the API returned 2 user resources, expected one"
        );
    }

    #[test]
    fn path_segments_refuse_route_hijacking() {
        assert!(safe_segment("app slug", "wordpress").is_ok());
        for bad in ["", "a/b", "a?b", "a#b", "a%2Fb", "..", "a..b", "a b"] {
            assert!(
                safe_segment("app slug", bad).is_err(),
                "{bad:?} must be refused"
            );
        }
        let err = safe_segment("organization id", "x/y").unwrap_err();
        assert_eq!(err.to_string(), "invalid organization id: x/y");
        // The wallet commands guard their org id too.
        let client = client("http://127.0.0.1:1");
        let err = wallet_balance(&client, "../wallet", Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "invalid organization id: ../wallet");
        let err = wallet_runway(&client, "?org=", Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "invalid organization id: ?org=");
        let err = apps_show(&client, "a/b", Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "invalid app slug: a/b");
        let err = instances_status(&client, "a/b", Output::Table).unwrap_err();
        assert_eq!(err.to_string(), "invalid instance id: a/b");
    }

    #[test]
    fn deployed_cell_keeps_the_raw_stamp_when_unparseable() {
        assert_eq!(deployed_cell(Some(&json!("nonsense")), NOW), "nonsense");
        assert_eq!(
            deployed_cell(Some(&json!("2026-11-04T21:00:00Z")), NOW),
            "3h ago (2026-11-04T21:00:00Z)"
        );
        assert_eq!(deployed_cell(Some(&Value::Null), NOW), "-");
        assert_eq!(deployed_cell(None, NOW), "-");
    }

    #[test]
    fn json_rows_carry_the_resource_level_id() {
        let rendered = apps_list_rendered(
            document(json!({"data": [
                {"type": "app", "id": "app-1", "attributes": {"name": "WordPress", "slug": "wordpress"}}
            ]})),
            Output::Json,
        )
        .unwrap();
        let attrs: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(attrs[0]["id"], "app-1");

        let rendered = instances_status_rendered(
            document(json!({
                "data": {"type": "instance", "id": "i1", "attributes": {"status": "running"}}
            })),
            Output::Json,
            NOW,
        )
        .unwrap();
        let attrs: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(attrs["id"], "i1");
    }

    #[test]
    fn non_404_errors_pass_through_get_or_404_verbatim() {
        // A 403 must keep the scope detail, not read as "no such thing".
        let server = serve(&respond(
            "403 Forbidden",
            r#"{"errors":[{"status":"403","title":"Forbidden","detail":"token lacks the instances:read scope"}]}"#,
        ));
        let err = instances_status(&client(&server.base_url), "i1", Output::Table).unwrap_err();
        assert_eq!(
            err.to_string(),
            "403 Forbidden: token lacks the instances:read scope"
        );
    }
}
