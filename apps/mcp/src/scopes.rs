//! The tool catalog's scope rule, replicated from the platform's own
//! `FluxVale.Api.Scopes` (#361) as a pure function: which tool needs
//! which scope, and write-implies-read. Pure — no client, no network —
//! so the filter decision is testable on its own; the coverage (what
//! the token may actually do) is the calling token's own scope list
//! from GET /me's `meta.scopes` (#585, W2b), which is the real
//! enforcement either way — the platform's 403s decide at the route.

/// The required scope for a catalog tool name. `None` is the /me
/// posture: any live token (identity reads are scopeless, scopes.ex's
/// `:any`). The write tools carry the domain's `:write` scope; the
/// destructive pair is `instances:write`/`backups:write` like every
/// other write of its domain — the elicitation gate is on top of the
/// scope, not instead of it.
pub(crate) fn required_scope(tool: &str) -> Option<&'static str> {
    match tool {
        "whoami" | "topup" => None,
        "apps_list" | "apps_show" => Some("catalog:read"),
        "instances_list" | "instances_status" => Some("instances:read"),
        // The scaffold reads instances, backups, gateways, and domains;
        // its primary scope is the instance read. Callers need the
        // union — the platform's route scopes are the enforcement.
        "terraform_import_bundle" => Some("instances:read"),
        "instances_deploy" | "instances_stop" | "instances_start" | "instances_destroy" => {
            Some("instances:write")
        }
        "backups_status" => Some("backups:read"),
        "backups_configure" | "backups_run" | "backups_restore" => Some("backups:write"),
        "wallet_balance" | "wallet_runway" | "wallet_ledger" => Some("wallet:read"),
        // Deny-by-default: a name outside the catalog is never visible.
        _ => Some(""),
    }
}

/// Is `tool` in the catalog, and does the token's granted scope list
/// cover it? The tools/list filter: the /me-scopeless pair always;
/// anything else asks the platform's grant rule ([`grants`]) against
/// the exact list /me reported. Unknown tools are never visible.
pub(crate) fn tool_visible(tool: &str, granted: &[String]) -> bool {
    match required_scope(tool) {
        None => true,
        Some("") => false,
        Some(required) => grants(granted, required),
    }
}

/// Does `granted` cover `required`? An exact match always does, and a
/// domain's `write` grant covers its `read` scope — write implies
/// read (`Scopes.grants?`'s rule). `read` never implies `write`.
pub(crate) fn grants(granted: &[String], required: &str) -> bool {
    let write_counterpart = write_counterpart(required);
    granted
        .iter()
        .any(|scope| scope == required || scope == &write_counterpart)
}

/// "instances:read" → "instances:write". For anything that isn't a
/// `:read` scope the counterpart equals the input, which the first
/// membership test already covered.
fn write_counterpart(required: &str) -> String {
    required
        .strip_suffix(":read")
        .map(|domain| format!("{domain}:write"))
        .unwrap_or_else(|| required.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The catalog, in tools/list order (rmcp's list_all sorts by name).
    const CATALOG: [&str; 18] = [
        "apps_list",
        "apps_show",
        "backups_configure",
        "backups_restore",
        "backups_run",
        "backups_status",
        "instances_deploy",
        "instances_destroy",
        "instances_list",
        "instances_start",
        "instances_status",
        "instances_stop",
        "terraform_import_bundle",
        "topup",
        "wallet_balance",
        "wallet_ledger",
        "wallet_runway",
        "whoami",
    ];

    fn granted(scopes: &[&str]) -> Vec<String> {
        scopes.iter().map(|scope| scope.to_string()).collect()
    }

    fn visible(scopes: &[&str]) -> Vec<&'static str> {
        let granted = granted(scopes);
        CATALOG
            .into_iter()
            .filter(|tool| tool_visible(tool, &granted))
            .collect()
    }

    #[test]
    fn a_full_scope_token_sees_all_eighteen_tools() {
        assert_eq!(
            visible(&[
                "catalog:read",
                "instances:read",
                "instances:write",
                "backups:read",
                "backups:write",
                "wallet:read"
            ])
            .len(),
            18
        );
    }

    #[test]
    fn a_catalog_only_token_sees_the_apps_pair_and_the_scopeless_pair() {
        assert_eq!(
            visible(&["catalog:read"]),
            ["apps_list", "apps_show", "topup", "whoami"]
        );
    }

    #[test]
    fn an_instances_only_token_sees_the_instances_family() {
        // Read scope: the reads, never the write verbs.
        assert_eq!(
            visible(&["instances:read"]),
            [
                "instances_list",
                "instances_status",
                "terraform_import_bundle",
                "topup",
                "whoami"
            ]
        );
    }

    #[test]
    fn write_implies_read_and_unlocks_the_domains_verbs() {
        // An instances:write token: the deploy/stop/start/destroy verbs
        // AND the instances reads (write implies read) — but nothing
        // else.
        assert_eq!(
            visible(&["instances:write"]),
            [
                "instances_deploy",
                "instances_destroy",
                "instances_list",
                "instances_start",
                "instances_status",
                "instances_stop",
                "terraform_import_bundle",
                "topup",
                "whoami"
            ]
        );
        // Read never implies write.
        assert!(!grants(&granted(&["instances:read"]), "instances:write"));
        // Unrelated domains don't cover; an exact match does.
        assert!(!grants(&granted(&["wallet:read"]), "instances:read"));
        assert!(grants(&granted(&["backups:write"]), "backups:write"));
    }

    #[test]
    fn a_token_with_no_scopes_still_gets_the_scopeless_pair() {
        // The protocol stays; tools/list just omits what it can't call.
        // /me renders a zero-scope PAT's list as [], never an omission.
        assert_eq!(visible(&[]), ["topup", "whoami"]);
        assert_eq!(visible(&["gateways:read"]), ["topup", "whoami"]);
    }

    #[test]
    fn the_backups_and_wallet_families_gate_on_their_domains() {
        assert_eq!(
            visible(&["backups:read"]),
            ["backups_status", "topup", "whoami"]
        );
        // backups:write implies backups:read (the status tool rides along).
        assert_eq!(
            visible(&["backups:write"]),
            [
                "backups_configure",
                "backups_restore",
                "backups_run",
                "backups_status",
                "topup",
                "whoami"
            ]
        );
        assert_eq!(
            visible(&["wallet:read"]),
            [
                "topup",
                "wallet_balance",
                "wallet_ledger",
                "wallet_runway",
                "whoami"
            ]
        );
    }

    #[test]
    fn required_scope_names_the_catalog_rule() {
        assert_eq!(required_scope("whoami"), None);
        assert_eq!(required_scope("topup"), None);
        assert_eq!(required_scope("apps_list"), Some("catalog:read"));
        assert_eq!(required_scope("instances_deploy"), Some("instances:write"));
        assert_eq!(required_scope("instances_destroy"), Some("instances:write"));
        assert_eq!(required_scope("backups_status"), Some("backups:read"));
        assert_eq!(required_scope("backups_restore"), Some("backups:write"));
        assert_eq!(required_scope("wallet_ledger"), Some("wallet:read"));
        assert_eq!(
            required_scope("terraform_import_bundle"),
            Some("instances:read")
        );
    }

    #[test]
    fn unknown_tools_are_never_visible() {
        // Deny-by-default: no name outside the catalog sneaks through,
        // whatever the granted list.
        assert!(!tool_visible(
            "set_instance_exposure",
            &granted(&["instances:write"])
        ));
        assert_eq!(required_scope("create_gateway"), Some(""));
    }
}
