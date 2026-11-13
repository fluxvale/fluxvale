//! The Terraform import scaffold (#763): discover an organization's
//! live resources over `/api/v1`, then render `versions.tf`,
//! `imports.tf`, and `README.md`. Resource bodies are deliberately
//! absent — `terraform plan -generate-config-out` writes those from
//! the provider's own schema, so this emitter cannot rot as the
//! schema moves.

use crate::{ApiClient, ApiError, Document, Resource};
use serde_json::Value;
use std::collections::{BTreeMap, HashSet};

/// One rendered scaffold file, in write order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GeneratedFile {
    pub name: &'static str,
    pub contents: String,
}

/// The three files `fluxvale terraform import` writes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bundle {
    /// The resolved organization's slug.
    pub organization: String,
    pub files: Vec<GeneratedFile>,
}

impl Bundle {
    /// The file named `name`, if the bundle carries it.
    pub fn file(&self, name: &str) -> Option<&GeneratedFile> {
        self.files.iter().find(|file| file.name == name)
    }
}

/// A discovery or rendering refusal. API failures stay transparent so
/// the CLI and MCP can keep the platform's own words.
#[derive(Debug, thiserror::Error)]
pub enum TerraformError {
    #[error(transparent)]
    Api(#[from] ApiError),
    #[error("{0}")]
    Message(String),
}

/// An organization as the scaffold names it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Org {
    pub id: String,
    pub slug: String,
    pub name: Option<String>,
}

/// One live resource family's row. Only the fields the scaffold needs:
/// the import id and the address basis.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Instance {
    pub id: String,
    pub name: String,
    pub slug: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackupSetting {
    pub instance_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccessGateway {
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CustomDomain {
    pub id: String,
    pub domain: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SsoWiring {
    pub instance_id: String,
}

/// Everything the org exposes that the provider can import.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Estate {
    pub org: Org,
    pub instances: Vec<Instance>,
    pub backup_settings: Vec<BackupSetting>,
    pub gateway: Option<AccessGateway>,
    pub custom_domains: Vec<CustomDomain>,
    pub sso_wirings: Vec<SsoWiring>,
}

/// Discover `org` (id or slug) and render its import scaffold.
///
/// Reads only: GET /organizations, GET /instances, each instance's
/// backup setting and PocketID wiring, the org's access gateway, and
/// the org's access domains. A missing singleton (no gateway, no
/// backup setting, no wiring) is a normal absence; anything else
/// propagates verbatim.
pub fn bundle(client: &ApiClient, org: &str) -> Result<Bundle, TerraformError> {
    bundle_at(client, org, Some(client.base_url()))
}

/// [`bundle`] with the provider's production default origin — no
/// `api_url` in `versions.tf`. The MCP tool uses this when the caller
/// did not name an origin, because its upstream URL may be an
/// in-cluster service name that a user's machine cannot resolve.
pub fn bundle_default(client: &ApiClient, org: &str) -> Result<Bundle, TerraformError> {
    bundle_at(client, org, None)
}

/// [`bundle`] with an explicit provider origin. Tests pass a stable
/// origin so the golden output does not carry a random test-server
/// port.
pub fn bundle_with(client: &ApiClient, org: &str, api_url: &str) -> Result<Bundle, TerraformError> {
    bundle_at(client, org, Some(api_url))
}

fn bundle_at(
    client: &ApiClient,
    org: &str,
    api_url: Option<&str>,
) -> Result<Bundle, TerraformError> {
    let api_url = validate_api_url(api_url)?;
    let estate = discover(client, org)?;
    Ok(render_with(&estate, api_url))
}

/// The provider's `api_url` is a URL, not arbitrary HCL text. An empty
/// or production-default origin means "omit it"; anything else must be
/// an http(s) origin with no whitespace or control characters.
fn validate_api_url(raw: Option<&str>) -> Result<Option<&str>, TerraformError> {
    let Some(raw) = raw else { return Ok(None) };
    let url = raw.trim_end_matches('/');
    if url.is_empty() || url == "https://fluxvale.com" {
        return Ok(None);
    }
    let lower = url.to_ascii_lowercase();
    let (scheme, rest) = if let Some(rest) = lower.strip_prefix("http://") {
        ("http", rest)
    } else if let Some(rest) = lower.strip_prefix("https://") {
        ("https", rest)
    } else {
        ("", "")
    };
    let host = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let shaped = !scheme.is_empty()
        && !host.is_empty()
        && !url.chars().any(|ch| ch.is_whitespace() || ch.is_control());
    if shaped {
        Ok(Some(url))
    } else {
        Err(TerraformError::Message(format!(
            "invalid api_url {raw:?}: expected an http(s) origin"
        )))
    }
}

/// The read half, exposed so tests can pin discovery separately from
/// rendering.
pub fn discover(client: &ApiClient, org: &str) -> Result<Estate, TerraformError> {
    let org = resolve_org(client, org)?;

    // The list route's default fields omit organization_id (status is
    // already included); ask for both explicitly so the org filter is a
    // wire fact and a dying row is not offered for import.
    let instances_doc =
        client.get("/instances?fields[instance]=id,name,slug,organization_id,status")?;
    let resources = instances_doc.resources();
    if let Some(resource) = resources.iter().find(|resource| {
        resource
            .attributes
            .get("organization_id")
            .and_then(Value::as_str)
            .is_none()
    }) {
        return Err(TerraformError::Message(format!(
            "the API did not echo organization_id for instance {} — refusing to guess which organization it belongs to",
            resource.id
        )));
    }
    let mut instances: Vec<Instance> = resources
        .into_iter()
        .filter(|resource| {
            resource
                .attributes
                .get("organization_id")
                .and_then(Value::as_str)
                == Some(org.id.as_str())
                // A deleting/lost row has no importable remote object;
                // importing it dies at apply rather than adopting it.
                && !matches!(
                    resource.attributes.get("status").and_then(Value::as_str),
                    Some("deleting" | "lost")
                )
        })
        .map(|resource| Instance {
            name: string_attr(&resource, "name").unwrap_or_default(),
            slug: string_attr(&resource, "slug").unwrap_or_default(),
            id: resource.id,
        })
        .collect();
    instances.sort_by(|a, b| a.slug.cmp(&b.slug).then(a.id.cmp(&b.id)));

    let mut backup_settings = Vec::new();
    let mut sso_wirings = Vec::new();
    for instance in &instances {
        if get_singleton(
            client,
            &format!("/instances/{}/backup-setting", instance.id),
            "backup setting",
        )?
        .is_some()
        {
            backup_settings.push(BackupSetting {
                instance_id: instance.id.clone(),
            });
        }
        if let Some(wiring) = get_singleton(
            client,
            &format!("/instances/{}/pocket-id-wiring", instance.id),
            "PocketID wiring",
        )? {
            sso_wirings.push(SsoWiring {
                instance_id: string_attr(&wiring, "instance_id")
                    .unwrap_or_else(|| instance.id.clone()),
            });
        }
    }

    let gateway = get_singleton(
        client,
        &format!("/organizations/{}/access-gateway", org.id),
        "access gateway",
    )?
    .map(|resource| AccessGateway { id: resource.id });

    let domains_doc = client.get(&format!("/organizations/{}/access-domains", org.id))?;
    let mut custom_domains: Vec<CustomDomain> = domains_doc
        .resources()
        .into_iter()
        // The platform mints one `platform` row per org for its own
        // instances base domain; the provider's custom-domain resource
        // only ever manages user-owned `custom` rows.
        .filter(|resource| {
            resource.attributes.get("kind").and_then(Value::as_str) == Some("custom")
        })
        .map(|resource| CustomDomain {
            domain: string_attr(&resource, "domain").unwrap_or_default(),
            id: resource.id,
        })
        .collect();
    custom_domains.sort_by(|a, b| a.domain.cmp(&b.domain).then(a.id.cmp(&b.id)));

    Ok(Estate {
        org,
        instances,
        backup_settings,
        gateway,
        custom_domains,
        sso_wirings,
    })
}

/// Render the estate into the three scaffold files. Pure: no network,
/// no filesystem, no resource bodies. Production is the provider's
/// default origin, so no `api_url` rides unless `render_with` names one.
pub fn render(estate: &Estate) -> Bundle {
    render_with(estate, None)
}

fn render_with(estate: &Estate, api_url: Option<&str>) -> Bundle {
    let mut instance_names = Namer::default();
    let instance_addresses: BTreeMap<String, String> = estate
        .instances
        .iter()
        .map(|instance| {
            let basis = if instance.slug.is_empty() {
                &instance.name
            } else {
                &instance.slug
            };
            (
                instance.id.clone(),
                instance_names.take(basis, &instance.id),
            )
        })
        .collect();

    let mut backup_names = Namer::default();
    let backup_by_instance: BTreeMap<&str, String> = estate
        .backup_settings
        .iter()
        .map(|setting| {
            let base = instance_addresses
                .get(&setting.instance_id)
                .cloned()
                .unwrap_or_else(|| identifier(&setting.instance_id));
            (
                setting.instance_id.as_str(),
                backup_names.take(&format!("{base}_backups"), &setting.instance_id),
            )
        })
        .collect();

    let mut gateway_names = Namer::default();
    let gateway_name = estate
        .gateway
        .as_ref()
        .map(|gateway| gateway_names.take(&format!("{}_gateway", estate.org.slug), &gateway.id));

    let mut domain_names = Namer::default();
    let domain_addresses: BTreeMap<&str, String> = estate
        .custom_domains
        .iter()
        .map(|domain| {
            (
                domain.id.as_str(),
                domain_names.take(&domain.domain, &domain.id),
            )
        })
        .collect();

    let mut sso_names = Namer::default();
    let sso_by_instance: BTreeMap<&str, String> = estate
        .sso_wirings
        .iter()
        .map(|wiring| {
            let base = instance_addresses
                .get(&wiring.instance_id)
                .cloned()
                .unwrap_or_else(|| identifier(&wiring.instance_id));
            (
                wiring.instance_id.as_str(),
                sso_names.take(&format!("{base}_sso"), &wiring.instance_id),
            )
        })
        .collect();

    let mut imports = String::new();
    imports.push_str(&format!(
        "# Generated by `fluxvale terraform import` for organization `{}` ({}).\n\
         # `tofu plan -generate-config-out=generated.tf` writes the resource\n\
         # bodies from the provider schema; this file only imports.\n",
        estate.org.slug, estate.org.id
    ));

    if estate.instances.is_empty()
        && estate.backup_settings.is_empty()
        && estate.gateway.is_none()
        && estate.custom_domains.is_empty()
        && estate.sso_wirings.is_empty()
    {
        imports.push_str("\n# No importable resources found in this organization.\n");
    } else {
        if !estate.instances.is_empty() {
            imports.push_str("\n# Instances\n");
            for instance in &estate.instances {
                let name = &instance_addresses[&instance.id];
                imports.push_str(&import_block(
                    &format!("fluxvale_instance.{name}"),
                    &instance.id,
                ));
            }
        }

        if !estate.backup_settings.is_empty() {
            imports.push_str("\n# Backup settings\n");
            for setting in &estate.backup_settings {
                let name = &backup_by_instance[setting.instance_id.as_str()];
                imports.push_str(&import_block(
                    &format!("fluxvale_instance_backups.{name}"),
                    // The provider imports this resource by instance id.
                    &setting.instance_id,
                ));
            }
        }

        if let Some(name) = &gateway_name {
            imports.push_str("\n# Access gateway\n");
            imports.push_str(&import_block(
                &format!("fluxvale_access_gateway.{name}"),
                // The provider imports by org id or slug.
                &estate.org.slug,
            ));
        }

        if !estate.custom_domains.is_empty() {
            imports.push_str("\n# Custom domains\n");
            for domain in &estate.custom_domains {
                let name = &domain_addresses[domain.id.as_str()];
                imports.push_str(&import_block(
                    &format!("fluxvale_custom_domain.{name}"),
                    // The provider imports by access-domain id.
                    &domain.id,
                ));
            }
        }

        if !estate.sso_wirings.is_empty() {
            imports.push_str(
                "\n# PocketID SSO wirings\n\
                 # Provider 0.3.0 does not implement import for this resource.\n\
                 # Uncomment these blocks after the provider gains import support.\n",
            );
            for wiring in &estate.sso_wirings {
                let name = &sso_by_instance[wiring.instance_id.as_str()];
                imports.push_str(&commented_import_block(
                    &format!("fluxvale_pocket_id_sso.{name}"),
                    // One wiring per instance; the instance id would be
                    // the provider's import id once it supports import.
                    &wiring.instance_id,
                ));
            }
        }
    }

    let versions = versions_tf(api_url);
    let readme = readme(estate);

    Bundle {
        organization: estate.org.slug.clone(),
        files: vec![
            GeneratedFile {
                name: "versions.tf",
                contents: versions,
            },
            GeneratedFile {
                name: "imports.tf",
                contents: imports,
            },
            GeneratedFile {
                name: "README.md",
                contents: readme,
            },
        ],
    }
}

fn versions_tf(api_url: Option<&str>) -> String {
    let mut rendered = "# Generated by `fluxvale terraform import`. Keep this file.\n\
     terraform {\n\
     \x20 required_providers {\n\
     \x20   fluxvale = {\n\
     \x20     source  = \"registry.terraform.io/fluxvale/fluxvale\"\n\
     \x20     version = \"~> 0.3\"\n\
     \x20   }\n\
     \x20 }\n\
     \n\
     \x20 # OpenTofu encrypts state at rest once this block names a key\n\
     \x20 # provider and method. See the state-encryption guide:\n\
     \x20 # https://opentofu.org/docs/language/state/encryption/\n\
     \x20 # encryption {\n\
     \x20 #   state {\n\
     \x20 #     enforced = true\n\
     \x20 #   }\n\
     \x20 # }\n\
     }\n\
     \n"
    .to_string();
    match api_url.map(|url| url.trim_end_matches('/')) {
        Some(url) if url != "https://fluxvale.com" && !url.is_empty() => {
            rendered.push_str(&format!(
                "provider \"fluxvale\" {{\n  api_url = \"{}\"\n}}\n",
                hcl_string(url)
            ));
        }
        _ => rendered.push_str("provider \"fluxvale\" {}\n"),
    }
    rendered
}

fn readme(estate: &Estate) -> String {
    let org = match &estate.org.name {
        Some(name) if !name.is_empty() && name != &estate.org.slug => {
            format!("{} ({})", name, estate.org.slug)
        }
        _ => estate.org.slug.clone(),
    };
    let mut readme = format!(
        "# Terraform import scaffold\n\
         \n\
         Generated by `fluxvale terraform import --org {}` for **{}**.\n\
         \n\
         This directory imports the live estate; it does not render resource\n\
         bodies. Finish the adoption:\n\
         \n\
         ```sh\n\
         tofu init\n\
         tofu plan -generate-config-out=generated.tf\n\
         tofu apply\n\
         ```\n\
         \n\
         `-generate-config-out` writes `generated.tf` from the provider schema.\n\
         Review it, then run `tofu plan` again until it is clean.\n\
         \n\
         ## What the scaffold found\n\
         \n\
         | Resource | Count |\n\
         | --- | --- |\n\
         | `fluxvale_instance` | {} |\n\
         | `fluxvale_instance_backups` | {} |\n\
         | `fluxvale_access_gateway` | {} |\n\
         | `fluxvale_custom_domain` | {} |\n\
         | `fluxvale_pocket_id_sso` | {} |\n\
         \n\
         ## Caveats\n\
         \n\
         - **Write-only values are never readable back.** `generated.tf` cannot\n\
         \x20\x20carry `env_vars` or a backup's `secret_access_key`; re-add\n\
         \x20\x20`env_vars` in your Terraform config from your own records (the\n\
         \x20\x20provider writes them in place), and set the backup secret in the\n\
         \x20\x20panel.\n\
         - **Generated config may need small edits before the plan is clean.**\n\
         \x20\x20`app`/`app_version` on an imported instance have no wire echo, the\n\
         \x20\x20gateway's `instances` set is config-authoritative and starts null,\n\
         \x20\x20and `rotate_secret_on` is config-only posture. Fill in what you want\n\
         \x20\x20Terraform to manage, then re-plan.\n\
         - **Dying instances are skipped.** `deleting` and `lost` rows are not\n\
         \x20\x20offered for import — there is no remote object to adopt.\n",
        estate.org.slug,
        org,
        estate.instances.len(),
        estate.backup_settings.len(),
        if estate.gateway.is_some() { 1 } else { 0 },
        estate.custom_domains.len(),
        estate.sso_wirings.len()
    );
    if !estate.custom_domains.is_empty() {
        readme.push_str(
            "\nOnly user-owned (`custom`) access domains are exported; the\n\
             org's system-minted `platform` domain is not.\n",
        );
    }
    if !estate.sso_wirings.is_empty() {
        readme.push_str(
            "\n**Provider limitation:** provider 0.3.0 does not implement\n\
             `import` for `fluxvale_pocket_id_sso`. Its blocks are commented out\n\
             in `imports.tf`, with the instance id as the import id; uncomment\n\
             them once the provider release you use supports import.\n",
        );
    }
    readme
}

fn import_block(address: &str, id: &str) -> String {
    format!(
        "\nimport {{\n  to = {address}\n  id = \"{}\"\n}}\n",
        hcl_string(id)
    )
}

fn commented_import_block(address: &str, id: &str) -> String {
    format!(
        "\n# import {{\n#   to = {address}\n#   id = \"{}\"\n# }}\n",
        hcl_string(id)
    )
}

/// HCL's quoted-string escapes. Ids/slugs only need the quote/backslash
/// pair, but `api_url` is caller-supplied: escape the template sigils and
/// control characters too, so a URL can never become HCL expressions.
fn hcl_string(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            // HCL only treats `$${`/`%%{` as template escapes; a bare
            // `$$` or `%%` stays doubled, so look one char ahead.
            '$' if chars.peek() == Some(&'{') => out.push_str("$$"),
            '%' if chars.peek() == Some(&'{') => out.push_str("%%"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            other => out.push(other),
        }
    }
    out
}

fn string_attr(resource: &Resource, name: &str) -> Option<String> {
    resource
        .attributes
        .get(name)
        .and_then(Value::as_str)
        .map(str::to_owned)
}

/// A one-resource read whose 404 is absence, not an error.
fn get_singleton(
    client: &ApiClient,
    path: &str,
    what: &str,
) -> Result<Option<Resource>, TerraformError> {
    let document = match client.get(path) {
        Ok(document) => document,
        Err(ApiError::NotFound) => return Ok(None),
        Err(err) => return Err(err.into()),
    };
    one_resource(document, what)
}

/// A singleton document's resource: absent or exactly one is normal; a
/// duplicate is a contract violation, not a silent pick.
fn one_resource(document: Document, what: &str) -> Result<Option<Resource>, TerraformError> {
    let mut resources = document.resources();
    match resources.len() {
        0 => Ok(None),
        1 => Ok(Some(resources.remove(0))),
        n => Err(TerraformError::Message(format!(
            "the API returned {n} {what} resources, expected one"
        ))),
    }
}

fn resolve_org(client: &ApiClient, spec: &str) -> Result<Org, TerraformError> {
    let spec = spec.trim();
    if spec.is_empty() {
        return Err(TerraformError::Message(
            "an organization slug or id is required".to_string(),
        ));
    }
    let document: Document = client.get("/organizations")?;
    let mut orgs: Vec<Org> = document
        .resources()
        .into_iter()
        .map(|resource| Org {
            slug: string_attr(&resource, "slug").unwrap_or_default(),
            name: string_attr(&resource, "name"),
            id: resource.id,
        })
        .collect();
    orgs.sort_by(|a, b| a.slug.cmp(&b.slug).then(a.id.cmp(&b.id)));
    if let Some(org) = orgs
        .iter()
        .find(|org| org.id == spec || org.slug.eq_ignore_ascii_case(spec))
    {
        return Ok(org.clone());
    }
    let yours = orgs
        .iter()
        .map(|org| format!("{} ({})", org.slug, org.id))
        .collect::<Vec<_>>()
        .join(", ");
    Err(TerraformError::Message(if yours.is_empty() {
        format!("no organization with id or slug {spec:?}; your token belongs to none")
    } else {
        format!("no organization with id or slug {spec:?}; yours: {yours}")
    }))
}

/// HCL label derivation: lowercase ASCII alphanumerics and underscores,
/// with every other rune folded to `_`. A leading digit gets `r_`.
fn identifier(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for ch in raw.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
        } else if !out.ends_with('_') {
            out.push('_');
        }
    }
    let out = out.trim_matches('_');
    let out = if out.is_empty() { "resource" } else { out };
    if out.starts_with(|ch: char| ch.is_ascii_digit()) {
        format!("r_{out}")
    } else {
        out.to_string()
    }
}

/// Per-resource-type address allocator. `take` keeps the first readable
/// name, then appends `_2`, `_3`, … in encounter order — deterministic
/// because discovery sorts its input.
#[derive(Default)]
struct Namer {
    used: HashSet<String>,
}

impl Namer {
    fn take(&mut self, basis: &str, id: &str) -> String {
        let base = identifier(if basis.trim().is_empty() { id } else { basis });
        if self.used.insert(base.clone()) {
            return base;
        }
        let mut suffix = 2;
        loop {
            let candidate = format!("{base}_{suffix}");
            if self.used.insert(candidate.clone()) {
                return candidate;
            }
            suffix += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn estate() -> Estate {
        Estate {
            org: Org {
                id: "org-acme".into(),
                slug: "acme".into(),
                name: Some("Acme".into()),
            },
            instances: vec![
                Instance {
                    id: "i-web".into(),
                    name: "Web".into(),
                    slug: "web-a1b2".into(),
                },
                Instance {
                    id: "i-api".into(),
                    name: "API".into(),
                    slug: "web-a1b2".into(),
                },
            ],
            backup_settings: vec![BackupSetting {
                instance_id: "i-web".into(),
            }],
            gateway: Some(AccessGateway { id: "g1".into() }),
            custom_domains: vec![
                CustomDomain {
                    id: "d1".into(),
                    domain: "Apps.Example.com".into(),
                },
                CustomDomain {
                    id: "d2".into(),
                    domain: "apps.example.com".into(),
                },
            ],
            sso_wirings: vec![SsoWiring {
                instance_id: "i-web".into(),
            }],
        }
    }

    #[test]
    fn addresses_are_readable_and_collisions_get_a_deterministic_suffix() {
        let bundle = render(&estate());
        let imports = &bundle.file("imports.tf").unwrap().contents;
        assert!(imports.contains("to = fluxvale_instance.web_a1b2\n"));
        assert!(imports.contains("to = fluxvale_instance.web_a1b2_2\n"));
        assert!(imports.contains("to = fluxvale_instance_backups.web_a1b2_backups\n"));
        assert!(imports.contains("to = fluxvale_access_gateway.acme_gateway\n"));
        assert!(imports.contains("to = fluxvale_custom_domain.apps_example_com\n"));
        assert!(imports.contains("to = fluxvale_custom_domain.apps_example_com_2\n"));
        assert!(imports.contains("# import {\n#   to = fluxvale_pocket_id_sso.web_a1b2_sso\n"));
        // Provider 0.3.0 has no importer for SSO: an active block would
        // fail the whole adoption plan, so it must stay commented.
        assert!(!imports.contains("\nimport {\n  to = fluxvale_pocket_id_sso"));

        // Rendering the same estate twice is byte-identical.
        assert_eq!(render(&estate()), bundle);
    }

    #[test]
    fn import_ids_follow_each_resources_own_shape() {
        let imports = render(&estate())
            .file("imports.tf")
            .unwrap()
            .contents
            .clone();
        assert!(imports.contains("to = fluxvale_instance.web_a1b2\n  id = \"i-web\""));
        // Backups and SSO import by instance id, not their row id.
        assert!(imports.contains("fluxvale_instance_backups.web_a1b2_backups\n  id = \"i-web\""));
        assert!(
            imports.contains("#   to = fluxvale_pocket_id_sso.web_a1b2_sso\n#   id = \"i-web\"")
        );
        // The gateway imports by org slug; domains by access-domain id.
        assert!(imports.contains("fluxvale_access_gateway.acme_gateway\n  id = \"acme\""));
        assert!(imports.contains("fluxvale_custom_domain.apps_example_com\n  id = \"d1\""));
    }

    #[test]
    fn versions_and_readme_carry_the_adoption_contract() {
        let bundle = render(&estate());
        let versions = &bundle.file("versions.tf").unwrap().contents;
        assert!(versions.contains("source  = \"registry.terraform.io/fluxvale/fluxvale\""));
        assert!(versions.contains("provider \"fluxvale\" {}"));
        assert!(versions.contains("# encryption {"));
        assert!(versions.contains("enforced = true"));
        assert!(versions.contains("opentofu.org/docs/language/state/encryption"));

        let readme = &bundle.file("README.md").unwrap().contents;
        assert!(readme.contains("tofu init"));
        assert!(readme.contains("tofu plan -generate-config-out=generated.tf"));
        assert!(readme.contains("tofu apply"));
        assert!(readme.contains("`env_vars`"));
        assert!(readme.contains("`secret_access_key`"));
        assert!(readme.contains("provider 0.3.0 does not implement"));
        assert!(readme.contains("Its blocks are commented out"));
        assert!(readme.contains("`platform` domain is not"));
        assert!(!readme.contains("secrets path"));
        assert!(readme.contains("re-add"));
        assert!(readme.contains("backup secret"));
    }

    #[test]
    fn a_non_default_origin_rides_the_provider_block() {
        let versions = versions_tf(Some("https://staging.fluxvale.com/"));
        assert!(
            versions.contains(
                "provider \"fluxvale\" {\n  api_url = \"https://staging.fluxvale.com\"\n}"
            )
        );
        // Production is the provider default: keep the block empty.
        let prod = versions_tf(Some("https://fluxvale.com"));
        assert!(prod.contains("provider \"fluxvale\" {}"));
        // An empty origin is not a URL to write.
        let empty = versions_tf(Some(""));
        assert!(empty.contains("provider \"fluxvale\" {}"));
    }

    #[test]
    fn an_empty_estate_still_renders_a_valid_scaffold() {
        let empty = Estate {
            org: Org {
                id: "org1".into(),
                slug: "empty".into(),
                name: None,
            },
            ..Estate::default()
        };
        let bundle = render(&empty);
        assert!(
            bundle
                .file("imports.tf")
                .unwrap()
                .contents
                .contains("# No importable resources found in this organization.")
        );
        let readme = &bundle.file("README.md").unwrap().contents;
        assert!(!readme.contains("| 1 |"));
        assert!(readme.contains("for **empty**."));
        assert!(!readme.contains("empty (empty)"));
    }

    #[test]
    fn a_resource_whose_instance_vanished_falls_back_to_its_id() {
        let orphan = Estate {
            org: Org {
                id: "org1".into(),
                slug: "acme".into(),
                name: Some("Acme".into()),
            },
            backup_settings: vec![BackupSetting {
                instance_id: "i-gone".into(),
            }],
            sso_wirings: vec![SsoWiring {
                instance_id: "i-gone".into(),
            }],
            ..Estate::default()
        };
        let bundle = render(&orphan);
        let imports = &bundle.file("imports.tf").unwrap().contents;
        assert!(imports.contains("fluxvale_instance_backups.i_gone_backups"));
        assert!(imports.contains("#   to = fluxvale_pocket_id_sso.i_gone_sso"));
    }

    #[test]
    fn a_duplicate_singleton_document_is_loud() {
        let document: Document = serde_json::from_value(serde_json::json!({"data": [
            {"type": "backup_setting", "id": "b1", "attributes": {}},
            {"type": "backup_setting", "id": "b2", "attributes": {}}
        ]}))
        .unwrap();
        let error = one_resource(document, "backup setting")
            .unwrap_err()
            .to_string();
        assert_eq!(
            error,
            "the API returned 2 backup setting resources, expected one"
        );
    }

    #[test]
    fn an_api_url_must_be_an_http_origin() {
        assert_eq!(validate_api_url(None).unwrap(), None);
        assert_eq!(
            validate_api_url(Some("https://fluxvale.com/")).unwrap(),
            None
        );
        assert_eq!(
            validate_api_url(Some("https://staging.fluxvale.com/")).unwrap(),
            Some("https://staging.fluxvale.com")
        );
        assert_eq!(
            validate_api_url(Some("HTTPS://Staging.Fluxvale.com/")).unwrap(),
            Some("HTTPS://Staging.Fluxvale.com")
        );
        for bad in [
            "ftp://example.com",
            "https://example.com/with space",
            "https://example.com/\n",
            "https://?nohost",
            "staging.fluxvale.com",
        ] {
            let error = validate_api_url(Some(bad)).unwrap_err().to_string();
            assert!(error.contains("invalid api_url"), "{bad}: {error}");
        }
    }

    #[test]
    fn hcl_strings_cannot_become_template_expressions() {
        assert_eq!(hcl_string("a\"b\\c"), "a\\\"b\\\\c");
        assert_eq!(
            hcl_string("${file(\"/etc/passwd\")}"),
            "$${file(\\\"/etc/passwd\\\")}"
        );
        assert_eq!(hcl_string("100%"), "100%");
        assert_eq!(hcl_string("100%{"), "100%%{");
        assert_eq!(hcl_string("a$b"), "a$b");
        assert_eq!(hcl_string("a\nb"), "a\\nb");
    }

    #[test]
    fn an_empty_org_spec_is_refused_before_the_wire() {
        // The client points at a dead port; reaching it would mean the
        // local fence failed.
        let client = ApiClient::new("http://127.0.0.1:1", crate::Token::new("fvpat_test"));
        let error = resolve_org(&client, "  ").unwrap_err().to_string();
        assert_eq!(error, "an organization slug or id is required");
    }

    #[test]
    fn identifiers_fold_punctuation_and_leading_digits() {
        assert_eq!(identifier("web-a1b2"), "web_a1b2");
        assert_eq!(identifier("Apps.Example.com"), "apps_example_com");
        assert_eq!(identifier("01ABC"), "r_01abc");
        assert_eq!(identifier("---"), "resource");
        assert_eq!(identifier("  a  b  "), "a_b");
    }
}
