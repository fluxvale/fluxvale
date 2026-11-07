//! The tool catalog's scope rule, replicated from the platform's own
//! `FluxVale.Api.Scopes` (#361) as a pure function: which tool needs
//! which scope, and write-implies-read. Pure — no client, no network —
//! so the filter decision is testable on its own; the coverage
//! (what the token may actually do) comes from the platform, which is
//! the real enforcement either way.

/// The required scope for a catalog tool name. `None` is the /me
/// posture: any live token (identity reads are scopeless, scopes.ex's
/// `:any`). Write tools (W2b) will land here with their `:write`
/// scopes.
pub(crate) fn required_scope(tool: &str) -> Option<&'static str> {
    match tool {
        "whoami" => None,
        "apps_list" | "apps_show" => Some("catalog:read"),
        "instances_list" | "instances_status" => Some("instances:read"),
        // Deny-by-default: a name outside the catalog is never visible.
        _ => Some(""),
    }
}

/// The scope set the tools/list probes discovered — the domains whose
/// reads passed at the platform's own boundary. The write-implies-read
/// rule is already inside these answers (a write-scoped token passes
/// the read probe); this is the honest scope knowledge the wire gives.
pub(crate) fn coverage(catalog_read: bool, instances_read: bool) -> Vec<&'static str> {
    [
        ("catalog:read", catalog_read),
        ("instances:read", instances_read),
    ]
    .into_iter()
    .filter_map(|(scope, ok)| ok.then_some(scope))
    .collect()
}

/// Is `tool` in the catalog, and does the discovered coverage cover
/// it? The tools/list filter: `whoami` always; anything else asks the
/// platform's grant rule ([`grants`]) against what the probes found.
/// Unknown tools are never visible.
pub(crate) fn tool_visible(tool: &str, discovered: &[&str]) -> bool {
    match required_scope(tool) {
        None => true,
        Some(required) => grants(discovered, required),
    }
}

/// Does `granted` cover `required`? An exact match always does, and a
/// domain's `write` grant covers its `read` scope — write implies
/// read (`Scopes.grants?`'s rule). `read` never implies `write`.
pub(crate) fn grants(granted: &[&str], required: &str) -> bool {
    granted.contains(&required) || granted.contains(&write_counterpart(required).as_str())
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
    const CATALOG: [&str; 5] = [
        "apps_list",
        "apps_show",
        "instances_list",
        "instances_status",
        "whoami",
    ];

    fn visible(scopes: &[&str]) -> Vec<&'static str> {
        // The full-scope discovery: the coverage a token's scopes give.
        let discovered = coverage(
            grants(scopes, "catalog:read"),
            grants(scopes, "instances:read"),
        );
        CATALOG
            .into_iter()
            .filter(|tool| tool_visible(tool, &discovered))
            .collect()
    }

    #[test]
    fn a_full_scope_token_sees_all_five_tools() {
        let tools = visible(&["catalog:read", "instances:read"]);
        assert_eq!(tools.len(), 5);
        assert!(tools.contains(&"whoami"));
    }

    #[test]
    fn a_catalog_only_token_sees_whoami_and_the_apps_pair() {
        let tools = visible(&["catalog:read"]);
        assert_eq!(tools, ["apps_list", "apps_show", "whoami"]);
    }

    #[test]
    fn an_instances_only_token_sees_whoami_and_the_instances_pair() {
        let tools = visible(&["instances:read"]);
        assert_eq!(tools, ["instances_list", "instances_status", "whoami"]);
    }

    #[test]
    fn a_token_with_no_matching_scopes_still_gets_whoami() {
        // The protocol stays; tools/list just omits what it can't call.
        assert_eq!(visible(&[]), ["whoami"]);
        assert_eq!(visible(&["wallet:read", "backups:write"]), ["whoami"]);
    }

    #[test]
    fn write_implies_read_for_its_domain() {
        // An instances:write token passes the instances:read probe at
        // the platform (Scopes.grants?); the filter honors the same rule.
        assert!(grants(&["instances:write"], "instances:read"));
        assert!(grants(&["gateways:write"], "gateways:read"));
        // Read never implies write.
        assert!(!grants(&["instances:read"], "instances:write"));
        // Unrelated domains don't cover.
        assert!(!grants(&["wallet:read"], "instances:read"));
        // An exact match always does.
        assert!(grants(&["catalog:read"], "catalog:read"));
    }

    #[test]
    fn required_scope_names_the_catalog_rule() {
        assert_eq!(required_scope("whoami"), None);
        assert_eq!(required_scope("apps_list"), Some("catalog:read"));
        assert_eq!(required_scope("apps_show"), Some("catalog:read"));
        assert_eq!(required_scope("instances_list"), Some("instances:read"));
        assert_eq!(required_scope("instances_status"), Some("instances:read"));
    }

    #[test]
    fn unknown_tools_are_never_visible() {
        // Deny-by-default: no name outside the catalog sneaks through,
        // whatever the coverage.
        assert!(!tool_visible(
            "wallet_balance",
            &["catalog:read", "instances:read"]
        ));
        assert_eq!(required_scope("destroy_instance"), Some(""));
    }

    #[test]
    fn coverage_collects_only_the_passed_domains() {
        assert_eq!(coverage(true, true), ["catalog:read", "instances:read"]);
        assert_eq!(coverage(true, false), ["catalog:read"]);
        assert_eq!(coverage(false, true), ["instances:read"]);
        assert!(coverage(false, false).is_empty());
    }
}
