//! The MCP surface: the [`FluxValeMcp`] handler — the read tools and
//! the write tools (deploy through destroy, the destructive pair
//! elicitation-gated), the initialize gate (GET /me, protocol-refuse
//! a dead token), and the scope-filtered tools/list (/me's
//! `meta.scopes`, one upstream read). Descriptions are agent-facing
//! copy in the retiring Elixir server's register.

use rmcp::{
    ErrorData, RoleServer, ServerHandler,
    handler::server::{
        tool::{InputResponses as ConfirmResponses, RequestState as SealedState, ToolRouter},
        wrapper::Parameters,
    },
    model::{
        CallToolResponse, CallToolResult, ContentBlock, DiscoverResult, ErrorCode,
        InitializeRequestParams, InitializeResult, ListToolsResult, PaginatedRequestParams,
        ServerCapabilities, ServerConfig, Tool,
    },
    service::RequestContext,
    tool, tool_handler, tool_router,
};
use std::{borrow::Cow, sync::Arc};

use crate::{auth::McpAuth, elicit, scopes, upstream};
use fluxvale_api::{ApiError, Token};
use serde_json::Value;

/// The agent-facing instructions: who this server serves, and that
/// the token decides what appears in tools/list.
const INSTRUCTIONS: &str = "FluxVale as tools for AI agents: reads over your \
account — your identity, the deployable app catalog, your instances' \
lifecycle, backups, and wallet — plus the write verbs, deploy through \
destroy. Policies are enforced exactly as over the HTTP API: you only \
ever see your own data, tools/list only ever offers what your token's \
scopes cover, and the destructive pair (instances_destroy, \
backups_restore) asks a yes/no confirmation before it acts — answer \
it, or use the panel.";

pub(crate) struct FluxValeMcp {
    /// The platform origin every tool call rides to. The server holds
    /// nothing else — no token, no session state.
    api_base_url: Arc<str>,
    tool_router: ToolRouter<FluxValeMcp>,
}

/// `apps_show`'s input.
#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub(crate) struct AppsShowParams {
    /// The app's URL slug (from `apps_list`).
    pub slug: String,
}

/// `instances_status`'s input — no id means the verbose list.
#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub(crate) struct InstanceStatusParams {
    /// The instance's id (from `instances_list`). Omit for the verbose
    /// list of all your instances.
    pub id: Option<String>,
}

/// `instances_deploy`'s input — the CLI's deploy flags, with `name`
/// required: the platform's create refuses a nameless body (the
/// attribute is allow_nil?-false and nothing derives it — there is no
/// "the app's name by default" on this wire).
#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub(crate) struct DeployParams {
    /// The app's URL slug (from `apps_list`).
    pub app: String,
    /// A name for the new instance — you name it; the wire requires
    /// one.
    pub name: String,
    /// CPU cores as the wire's decimal string, e.g. "0.5".
    pub cpu: Option<String>,
    /// Memory in megabytes.
    pub memory_mb: Option<i64>,
    /// Storage in gigabytes.
    pub storage_gb: Option<i64>,
    /// An exact app version id; omit to deploy the newest version
    /// (the versions route's own newest-first order — there is no
    /// published filter).
    pub version: Option<String>,
}

/// The one-id tools' input (`instances_stop`, `instances_start`,
/// `instances_destroy`).
#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub(crate) struct InstanceIdParams {
    /// The instance's id (from `instances_list`).
    pub id: String,
}

/// `backups_configure`'s input — identifiers only: the write-only
/// secret args (#503) are never parameters of this surface.
#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub(crate) struct ConfigureBackupsParams {
    /// The instance's id (from `instances_list`).
    pub instance_id: String,
    /// The S3 endpoint: http(s):// host[:port], no path.
    pub endpoint: String,
    /// The S3 bucket name.
    pub bucket: String,
    /// An optional key prefix inside the bucket (no leading/trailing
    /// slash).
    pub prefix: Option<String>,
    /// The S3 access key's id — an identifier; the secret is set in
    /// the panel.
    pub access_key_id: String,
    /// How many snapshots to keep (2-30; the server's default is 7).
    pub retention_keep: Option<u8>,
    /// `false` pauses backups (`true` by default).
    pub enabled: Option<bool>,
}

/// `backups_status`'s input.
#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub(crate) struct BackupInstanceParams {
    /// The instance's id (from `instances_list`).
    pub instance_id: String,
}

/// `backups_restore`'s input.
#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub(crate) struct RestoreParams {
    /// The instance's id (from `instances_list`).
    pub instance_id: String,
    /// The backup run to restore from — the newest successful one
    /// (find it with `backups_status`).
    pub backup_run_id: String,
}

/// The wallet reads' input — the org id `whoami` reports.
#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub(crate) struct OrgParams {
    /// The organization's id (from `whoami`).
    pub organization_id: String,
}

/// `wallet_ledger`'s input.
#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub(crate) struct LedgerParams {
    /// The organization's id (from `whoami`).
    pub organization_id: String,
    /// The previous response's `next_cursor`, to page.
    pub cursor: Option<String>,
    /// The page size (1-100; 25 by default).
    pub limit: Option<u32>,
}

#[tool_router]
impl FluxValeMcp {
    pub(crate) fn new(api_base_url: Arc<str>) -> Self {
        Self {
            api_base_url,
            tool_router: Self::tool_router(),
        }
    }

    /// The request's own bearer, lifted by the middleware (rmcp's
    /// documented pattern: the injected HTTP parts carry axum
    /// extensions). Per-request by design — the server stores nothing.
    fn token(&self, context: &RequestContext<RoleServer>) -> Result<Token, ErrorData> {
        let parts = context.extensions.get::<axum::http::request::Parts>();
        let auth = parts.and_then(|parts| parts.extensions.get::<McpAuth>().map(|McpAuth(t)| t));
        token_from_parts(parts, auth)
    }

    #[tool(
        description = "The identity this token carries: user id, email, platform \
role, username, and the organizations the user belongs to (id, slug and \
name each). Use it first to see who you are and to learn the ids the \
other tools take.",
        annotations(read_only_hint = true)
    )]
    async fn whoami(
        &self,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(upstream::whoami(self.api_base_url.clone(), token).await)
    }

    #[tool(
        description = "The deployable app catalog: one entry per app — id, name, \
slug, tagline, description, icon/source/docs URLs, file-access flag, \
category id. Slugs from here are what `apps_show` takes.",
        annotations(read_only_hint = true)
    )]
    async fn apps_list(
        &self,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(upstream::apps_list(self.api_base_url.clone(), token).await)
    }

    #[tool(
        description = "One catalog app by its URL slug: name, tagline, description, \
icon/source/docs URLs, file-access flag. Get the slug from `apps_list`. \
Errors when no app carries the slug.",
        annotations(read_only_hint = true)
    )]
    async fn apps_show(
        &self,
        Parameters(AppsShowParams { slug }): Parameters<AppsShowParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(upstream::apps_show(self.api_base_url.clone(), token, slug).await)
    }

    #[tool(
        description = "Your instances: one entry per deployed app — id, name, slug, \
namespace, lifecycle status, exposure, always-on flag, deployed-at. The \
ids are what `instances_status` takes.",
        annotations(read_only_hint = true)
    )]
    async fn instances_list(
        &self,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(upstream::instances_list(self.api_base_url.clone(), token).await)
    }

    #[tool(
        description = "One instance's full detail by id: lifecycle status, exposure, \
allocation (cpu/memory/storage), image, port, healthcheck path, \
file-access flag, deployed-at. Get the id from `instances_list`. Omit \
the id to get the verbose list of all your instances instead. Errors \
when the id is not one of your instances.",
        annotations(read_only_hint = true)
    )]
    async fn instances_status(
        &self,
        Parameters(InstanceStatusParams { id }): Parameters<InstanceStatusParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(upstream::instances_status(self.api_base_url.clone(), token, id).await)
    }

    #[tool(
        description = "Deploy an app as a new instance: resolves the app by its URL slug \
(from `apps_list`), picks the newest version (or the exact version id \
you pass), creates the instance, and enqueues the deploy. You name \
the instance (required); cpu/memory_mb/storage_gb optionally override \
the version's defaults. The org wallet must be funded — a 403 names \
the top-up path (the `topup` tool returns it). NOT idempotent: every \
call deploys a new instance.",
        annotations(destructive_hint = false)
    )]
    async fn instances_deploy(
        &self,
        Parameters(DeployParams {
            app,
            name,
            cpu,
            memory_mb,
            storage_gb,
            version,
        }): Parameters<DeployParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(
            upstream::instances_deploy(
                self.api_base_url.clone(),
                token,
                upstream::DeployWire {
                    app,
                    name,
                    cpu,
                    memory_mb,
                    storage_gb,
                    version,
                },
            )
            .await,
        )
    }

    #[tool(
        description = "Stop an instance — scale its app to zero (the pause). The running \
rate stops accruing; storage keeps accruing (the volume persists). \
Refuses unless the instance is running. Reverse with `instances_start`.",
        annotations(destructive_hint = false)
    )]
    async fn instances_stop(
        &self,
        Parameters(InstanceIdParams { id }): Parameters<InstanceIdParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(
            upstream::instances_lifecycle(self.api_base_url.clone(), token, id, "stop").await,
        )
    }

    #[tool(
        description = "Start a stopped or sleeping instance back up — lands starting, and \
the reconciler confirms readiness. Needs a positive wallet balance \
(the funded gate's 403 names the top-up path). The app bills hourly \
once running.",
        annotations(destructive_hint = false)
    )]
    async fn instances_start(
        &self,
        Parameters(InstanceIdParams { id }): Parameters<InstanceIdParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(
            upstream::instances_lifecycle(self.api_base_url.clone(), token, id, "start").await,
        )
    }

    #[tool(
        description = "DESTROY an instance: deletes the volume data and tears down all its \
Kubernetes resources, and the row goes with them. Asks first — the \
call returns a confirm question naming the instance, and the teardown \
only starts after a \"yes\". On a client that cannot confirm (no \
elicitation support) the tool refuses without touching anything — use \
the panel instead.",
        annotations(destructive_hint = true)
    )]
    async fn instances_destroy(
        &self,
        context: RequestContext<RoleServer>,
        Parameters(InstanceIdParams { id }): Parameters<InstanceIdParams>,
        SealedState(sealed): SealedState,
        ConfirmResponses(responses): ConfirmResponses,
    ) -> Result<CallToolResponse, ErrorData> {
        let token = self.token(&context)?;
        let Some(sealed) = sealed else {
            // First round: an incapable client never reaches the
            // question, and the verb never runs.
            if !elicit::confirm_capable(&context) {
                return Ok(text_error(elicit::honest_error("instances_destroy")).into());
            }
            // The scope check lands BEFORE the question (Elixir
            // parity: require_scope before ask_confirm) — a read-only
            // token gets its refusal without a human decision first.
            // The confirm round doesn't re-check: the seal already
            // proves this round passed it.
            if let Err(message) =
                require_domain_scope(self.api_base_url.clone(), &token, "instances:write").await
            {
                return Ok(text_error(message).into());
            }
            // Resolve first — the not-found posture surfaces BEFORE
            // the question (the Elixir server's own order).
            let instance = match upstream::instances_status(
                self.api_base_url.clone(),
                token.clone(),
                Some(id.clone()),
            )
            .await
            {
                Ok(row) => row,
                Err(message) => return Ok(text_error(message).into()),
            };
            let name = field(&instance, "name").unwrap_or_else(|| id.clone());
            let slug = field(&instance, "slug").unwrap_or_else(|| id.clone());
            let question =
                format!("destroy instance {name} ({slug}). All data is deleted. Confirm?");
            let pending = elicit::Pending::DestroyInstance { instance_id: id };
            let sealed = match elicit::seal(&token, &pending) {
                Ok(sealed) => sealed,
                Err(message) => return Ok(text_error(message).into()),
            };
            return Ok(elicit::input_required(question, sealed).into());
        };

        // The confirm round: the target that runs is the sealed one —
        // a re-sent confirm cannot steer a different id.
        match elicit::open(&token, &sealed) {
            Ok(elicit::Pending::DestroyInstance { instance_id }) => {
                match elicit::confirm_answer(&responses) {
                    elicit::ConfirmAnswer::Yes => {
                        let row = upstream::instances_destroy(
                            self.api_base_url.clone(),
                            token,
                            instance_id,
                        )
                        .await;
                        Ok(value_or_error(row).into())
                    }
                    elicit::ConfirmAnswer::Cancelled => Ok(text(elicit::CANCELLED).into()),
                }
            }
            Ok(elicit::Pending::RestoreBackup { .. }) => {
                Ok(text_error(elicit::WRONG_TOOL.to_string()).into())
            }
            Err(message) => Ok(text_error(message).into()),
        }
    }

    #[tool(
        description = "Save an instance's backup destination: S3 endpoint, bucket, prefix, \
access key id, retention, enabled — creating the settings row or \
updating the existing one, whichever applies. Identifiers only: the \
secret key and restic password are write-only and live in the \
instance's namespace Secret — set them in the panel, and backups \
cannot run until they exist.",
        annotations(destructive_hint = false)
    )]
    async fn backups_configure(
        &self,
        Parameters(ConfigureBackupsParams {
            instance_id,
            endpoint,
            bucket,
            prefix,
            access_key_id,
            retention_keep,
            enabled,
        }): Parameters<ConfigureBackupsParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(
            upstream::backups_configure(
                self.api_base_url.clone(),
                token,
                upstream::ConfigureBackupWire {
                    instance: instance_id,
                    endpoint,
                    bucket,
                    prefix,
                    access_key_id,
                    retention_keep,
                    enabled,
                },
            )
            .await,
        )
    }

    #[tool(
        description = "An instance's backup state: the settings row (or null when backups \
aren't configured) plus the latest run (kind, status, snapshot id, \
error summary, timestamps). Errors when the instance is not one of \
yours.",
        annotations(read_only_hint = true)
    )]
    async fn backups_status(
        &self,
        Parameters(BackupInstanceParams { instance_id }): Parameters<BackupInstanceParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(upstream::backups_status(self.api_base_url.clone(), token, instance_id).await)
    }

    #[tool(
        description = "Run a backup now: one snapshot to the instance's configured \
destination. Needs backups configured and enabled, the app deployed, \
no run already in flight, and a positive wallet balance — refusals \
surface the operation's own words. Returns the run row (it starts \
running; `backups_status` tracks the finish).",
        annotations(destructive_hint = false)
    )]
    async fn backups_run(
        &self,
        Parameters(BackupInstanceParams { instance_id }): Parameters<BackupInstanceParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(upstream::backups_run(self.api_base_url.clone(), token, instance_id).await)
    }

    #[tool(
        description = "RESTORE an instance's volume from a backup run — OVERWRITES the \
current volume state with the snapshot's. The run must be the newest \
successful backup. Asks first: the call returns a confirm question \
naming the run and the instance, and the restore only starts after a \
\"yes\". On a client that cannot confirm (no elicitation support) the \
tool refuses without touching anything — use the panel instead.",
        annotations(destructive_hint = true)
    )]
    async fn backups_restore(
        &self,
        context: RequestContext<RoleServer>,
        Parameters(RestoreParams {
            instance_id,
            backup_run_id,
        }): Parameters<RestoreParams>,
        SealedState(sealed): SealedState,
        ConfirmResponses(responses): ConfirmResponses,
    ) -> Result<CallToolResponse, ErrorData> {
        let token = self.token(&context)?;
        // The uuid fence (the Elixir schema's own pattern): a garbage
        // run id refuses BEFORE the question — a confirm round trip
        // for an unrestorable id is wasted work for the human.
        if !elicit::valid_run_id(&backup_run_id) {
            return Ok(text_error(format!(
                "invalid backup_run_id {backup_run_id}: must be a backup run id (a uuid, from backups_status)"
            ))
            .into());
        }
        let Some(sealed) = sealed else {
            if !elicit::confirm_capable(&context) {
                return Ok(text_error(elicit::honest_error("backups_restore")).into());
            }
            // The scope check before the question (Elixir parity:
            // require_scope before ask_confirm); the confirm round
            // doesn't re-check.
            if let Err(message) =
                require_domain_scope(self.api_base_url.clone(), &token, "backups:write").await
            {
                return Ok(text_error(message).into());
            }
            let instance = match upstream::instances_status(
                self.api_base_url.clone(),
                token.clone(),
                Some(instance_id.clone()),
            )
            .await
            {
                Ok(row) => row,
                Err(message) => return Ok(text_error(message).into()),
            };
            let name = field(&instance, "name").unwrap_or_else(|| instance_id.clone());
            let slug = field(&instance, "slug").unwrap_or_else(|| instance_id.clone());
            let question = format!(
                "restore snapshot {backup_run_id} onto instance {name} ({slug}). \
                 The current volume state is OVERWRITTEN. Confirm?"
            );
            let pending = elicit::Pending::RestoreBackup {
                instance_id,
                backup_run_id,
            };
            let sealed = match elicit::seal(&token, &pending) {
                Ok(sealed) => sealed,
                Err(message) => return Ok(text_error(message).into()),
            };
            return Ok(elicit::input_required(question, sealed).into());
        };

        match elicit::open(&token, &sealed) {
            Ok(elicit::Pending::RestoreBackup {
                instance_id,
                backup_run_id,
            }) => match elicit::confirm_answer(&responses) {
                elicit::ConfirmAnswer::Yes => {
                    let row = upstream::backups_restore(
                        self.api_base_url.clone(),
                        token,
                        instance_id,
                        backup_run_id,
                    )
                    .await;
                    Ok(value_or_error(row).into())
                }
                elicit::ConfirmAnswer::Cancelled => Ok(text(elicit::CANCELLED).into()),
            },
            Ok(elicit::Pending::DestroyInstance { .. }) => {
                Ok(text_error(elicit::WRONG_TOOL.to_string()).into())
            }
            Err(message) => Ok(text_error(message).into()),
        }
    }

    #[tool(
        description = "The organization's wallet: balance in whole cents, the paywall \
waiver flag. Takes the organization id `whoami` reports.",
        annotations(read_only_hint = true)
    )]
    async fn wallet_balance(
        &self,
        Parameters(OrgParams { organization_id }): Parameters<OrgParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(
            upstream::wallet_balance(self.api_base_url.clone(), token, organization_id).await,
        )
    }

    #[tool(
        description = "The organization's wallet runway projection: the balance, the current \
burn rate (micro-cents per hour), and the hours left at that rate — \
the string \"infinity\" when nothing accrues. Takes the organization \
id `whoami` reports.",
        annotations(read_only_hint = true)
    )]
    async fn wallet_runway(
        &self,
        Parameters(OrgParams { organization_id }): Parameters<OrgParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(
            upstream::wallet_runway(self.api_base_url.clone(), token, organization_id).await,
        )
    }

    #[tool(
        description = "The organization's ledger history, newest first, one entry per \
credit/debit: signed amount in whole cents, type, reason, the tax \
facts. Keyset-paginated: while a next page exists the answer carries \
`next_cursor` — pass it as `cursor` to page. Takes the organization \
id `whoami` reports.",
        annotations(read_only_hint = true)
    )]
    async fn wallet_ledger(
        &self,
        Parameters(LedgerParams {
            organization_id,
            cursor,
            limit,
        }): Parameters<LedgerParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let token = self.token(&context)?;
        tool_result(
            upstream::wallet_ledger(
                self.api_base_url.clone(),
                token,
                organization_id,
                cursor,
                limit,
            )
            .await,
        )
    }

    #[tool(
        description = "The panel's top-up URL for the org wallet — hand it to the human. \
No API call is made; the tool is a pointer, not a verb. Any live \
token may call it.",
        annotations(read_only_hint = true)
    )]
    async fn topup(
        &self,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        tool_result(Ok(
            serde_json::json!({ "url": upstream::topup_url(&self.api_base_url) }),
        ))
    }
}

/// [`FluxValeMcp::token`]'s arms, pure over the pieces the transport
/// hands the handler. The None arms are defense in depth — the
/// middleware guarantees both in the served shape.
fn token_from_parts(
    parts: Option<&axum::http::request::Parts>,
    auth: Option<&Token>,
) -> Result<Token, ErrorData> {
    parts.ok_or_else(|| {
        ErrorData::internal_error(
            "no HTTP context on the request — the bearer middleware did not run",
            None,
        )
    })?;
    auth.cloned().ok_or_else(|| {
        auth_error(
            "no bearer token on the request — configure this MCP \
             server's Authorization header"
                .to_string(),
        )
    })
}

/// A read's row(s) as structured content; any upstream refusal is a
/// TOOL error carrying the message verbatim — never a protocol error,
/// never scrubbed.
fn tool_result(row: Result<serde_json::Value, String>) -> Result<CallToolResult, ErrorData> {
    Ok(value_or_error(row))
}

/// [`tool_result`]'s two arms as a bare result — the gated verbs'
/// final answers (they return `CallToolResponse`).
fn value_or_error(row: Result<Value, String>) -> CallToolResult {
    match row {
        Ok(value) => CallToolResult::structured(value),
        Err(message) => CallToolResult::error(vec![ContentBlock::text(message)]),
    }
}

/// A one-line text success (the cancelled arm's answer).
fn text(message: &str) -> CallToolResult {
    CallToolResult::success(vec![ContentBlock::text(message)])
}

/// A one-line TOOL error (the honest no-capability refusal, the seal
/// refusals) — same shape as [`value_or_error`]'s Err arm.
fn text_error(message: String) -> CallToolResult {
    CallToolResult::error(vec![ContentBlock::text(message)])
}

/// A string field off a flat row — the confirm question names the
/// target by its own fields (name/slug), never the bare id.
fn field(row: &Value, name: &str) -> Option<String> {
    row.get(name).and_then(Value::as_str).map(str::to_owned)
}

/// The destructive pair's first-round scope check: /me's exact scope
/// list (one read) against the domain's write scope. A read-only
/// token gets the scope refusal BEFORE the human decision — the
/// Elixir server's order (require_scope before ask_confirm). The
/// refusal copy is its line too; anything /me itself fails with
/// surfaces as-is.
async fn require_domain_scope(
    base: Arc<str>,
    token: &Token,
    required: &'static str,
) -> Result<(), String> {
    let granted = upstream::me_scopes(base, token.clone())
        .await
        .map_err(|err| match err {
            upstream::ScopeError::Auth(message)
            | upstream::ScopeError::Shape(message)
            | upstream::ScopeError::Upstream(message) => message,
        })?;
    if scopes::grants(&granted, required) {
        Ok(())
    } else {
        Err(format!("this token lacks the {required} scope"))
    }
}

/// The protocol-level authentication error: the client must
/// reconfigure its token. The API's own words ride inside.
fn auth_error(message: String) -> ErrorData {
    ErrorData::new(
        ErrorCode::INVALID_REQUEST,
        Cow::Owned(format!("authentication failed: {message}")),
        None,
    )
}

/// Upstream is transiently unusable (429, 5xx, transport) — a protocol
/// error, verbatim line inside, no retries.
fn upstream_error(message: String) -> ErrorData {
    ErrorData::internal_error(format!("the FluxVale API is unavailable: {message}"), None)
}

/// The /me gate's error mapping (initialize and discover): 401/403 are
/// AUTH — the client must reconfigure its token; anything else is
/// upstream, verbatim.
fn gate_error(err: ApiError) -> ErrorData {
    match err {
        err @ (ApiError::Unauthorized | ApiError::Forbidden(_)) => auth_error(err.to_string()),
        other => upstream_error(other.to_string()),
    }
}

#[tool_handler]
impl ServerHandler for FluxValeMcp {
    fn get_info(&self) -> ServerConfig {
        let mut info = InitializeResult::new(ServerCapabilities::builder().enable_tools().build());
        info.server_info = rmcp::model::Implementation::new("FluxVale", env!("CARGO_PKG_VERSION"));
        info.instructions = Some(INSTRUCTIONS.to_string());
        info
    }

    /// The initialize gate: GET /me with the request's bearer. 401/403
    /// refuse the protocol handshake — the client must reconfigure its
    /// token. Anything else surfaces verbatim. (The handshake revs'
    /// entry point; the 2026-07-28 flow's is [`Self::discover`].)
    async fn initialize(
        &self,
        request: InitializeRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<InitializeResult, ErrorData> {
        let token = self.token(&context)?;
        upstream::check_me(self.api_base_url.clone(), token)
            .await
            .map_err(gate_error)?;
        context.peer.set_peer_info(request.clone());
        self.negotiate_initialize(&request)
    }

    /// The discovery gate — the 2026-07-28 rev's handshake
    /// replacement. Same rule as [`Self::initialize`]: the bearer must
    /// prove itself against /me before this server answers anything.
    async fn discover(
        &self,
        context: RequestContext<RoleServer>,
    ) -> Result<DiscoverResult, ErrorData> {
        let token = self.token(&context)?;
        upstream::check_me(self.api_base_url.clone(), token)
            .await
            .map_err(gate_error)?;
        Ok(DiscoverResult::from_server_info(
            self.supported_protocol_versions().into_owned(),
            self.get_info(),
        ))
    }

    /// The scope filter (the settled decision): /me fresh on EVERY
    /// tools/list — no caching; the stateless posture makes every
    /// request independent anyway. W2b's swap: the calling token's
    /// EXACT scope list (`meta.scopes`, #585) is the coverage — one
    /// upstream read, down from W2a's three boundary probes (the
    /// write domains were never probeable). The platform's own 403s
    /// are the real enforcement; this list is what the token may call.
    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        let token = self.token(&context)?;
        let granted = upstream::me_scopes(self.api_base_url.clone(), token)
            .await
            .map_err(|err| match err {
                upstream::ScopeError::Auth(message) => auth_error(message),
                // The shape mismatch's own line — not "the API is
                // unavailable": this /me answered, just not as a PAT
                // caller's /me does.
                upstream::ScopeError::Shape(message) => ErrorData::internal_error(message, None),
                upstream::ScopeError::Upstream(message) => upstream_error(message),
            })?;
        let tools: Vec<Tool> = self
            .tool_router
            .list_all()
            .into_iter()
            .filter(|tool| scopes::tool_visible(&tool.name, &granted))
            .collect();
        Ok(ListToolsResult::with_all_items(tools))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testapi::{self, CannedApi};
    use axum::{Router, body::Body, http::Method, http::Request, http::StatusCode};
    use serde_json::{Value, json};
    use tower::ServiceExt;

    /// A bare `http::request::Parts` (no transport needed).
    fn bare_parts() -> axum::http::request::Parts {
        axum::http::Request::builder()
            .body(())
            .unwrap()
            .into_parts()
            .0
    }

    #[test]
    fn the_token_arms_refuse_without_the_transport_guarantees() {
        // No HTTP context at all — the middleware never ran.
        let err = token_from_parts(None, None).unwrap_err();
        assert_eq!(err.code, ErrorCode::INTERNAL_ERROR);
        assert!(err.message.contains("no HTTP context"), "err: {err}");

        // A request context, but no credential in it — the shape that
        // would mean the middleware was bypassed.
        let parts = bare_parts();
        let err = token_from_parts(Some(&parts), None).unwrap_err();
        assert_eq!(err.code, ErrorCode::INVALID_REQUEST);
        assert!(err.message.contains("no bearer token"), "err: {err}");

        // The served shape: both present.
        let token = token_from_parts(Some(&parts), Some(&Token::new("fvpat_t"))).unwrap();
        assert_eq!(token.expose(), "fvpat_t");
    }

    const PAT_FULL: &str = "fvpat_full_scope";
    const PAT_CATALOG: &str = "fvpat_catalog_only";
    const PAT_DEAD: &str = "fvpat_revoked";

    // ---- drivers: a JSON-RPC POST through the real router

    fn app(server: &CannedApi) -> Router {
        crate::build_router(&server.base_url)
    }

    async fn mcp(app: &Router, body: Value, bearer: Option<&str>) -> (StatusCode, Value) {
        let method = body["method"].as_str().unwrap_or_default().to_string();
        // The header must agree with the body's own per-request version
        // when one rides _meta (rmcp's mismatch check).
        let version = body["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"]
            .as_str()
            .unwrap_or("2025-11-25")
            .to_string();
        let mut builder = Request::builder()
            .method(Method::POST)
            .uri("/mcp")
            // rmcp's DNS-rebinding guard validates the Host header
            // (loopback allowlist default) — real clients always send
            // one; the router oneshot doesn't, so name it here.
            .header("host", "localhost:4600")
            .header("content-type", "application/json")
            .header("accept", "application/json, text/event-stream")
            // The standard headers naming the method (SEP-2243); the
            // per-request protocol version header names a handshake
            // rev, so no per-request _meta is demanded of these. On
            // the stateless rev a tools/call also names its tool
            // (Mcp-Name is REQUIRED there, validated against the body).
            .header("mcp-protocol-version", version)
            .header("mcp-method", method.clone());
        if method == "tools/call"
            && let Some(name) = body["params"]["name"].as_str()
        {
            builder = builder.header("mcp-name", name);
        }
        if let Some(bearer) = bearer {
            builder = builder.header("authorization", format!("Bearer {bearer}"));
        }
        let request = builder.body(Body::from(body.to_string())).unwrap();
        let response = app.clone().oneshot(request).await.unwrap();
        let status = response.status();
        let bytes = http_body_util::BodyExt::collect(response.into_body())
            .await
            .unwrap()
            .to_bytes();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    async fn initialize(app: &Router, bearer: &str) -> (StatusCode, Value) {
        initialize_at(app, bearer, "2025-11-25").await
    }

    async fn initialize_at(app: &Router, bearer: &str, version: &str) -> (StatusCode, Value) {
        // A handshake-rev client: the version rides the BODY (no
        // per-request protocol header — that's the 2026-07-28 shape).
        let mut builder = Request::builder()
            .method(Method::POST)
            .uri("/mcp")
            .header("host", "localhost:4600")
            .header("content-type", "application/json")
            .header("accept", "application/json, text/event-stream")
            .header("mcp-method", "initialize");
        builder = builder.header("authorization", format!("Bearer {bearer}"));
        let request = builder
            .body(Body::from(
                json!({
                    "jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": {
                        "protocolVersion": version,
                        "capabilities": {},
                        "clientInfo": {"name": "w2a-test", "version": "0.0.0"}
                    }
                })
                .to_string(),
            ))
            .unwrap();
        let response = app.clone().oneshot(request).await.unwrap();
        let status = response.status();
        let bytes = http_body_util::BodyExt::collect(response.into_body())
            .await
            .unwrap()
            .to_bytes();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    /// The 2026-07-28 flow's discovery POST: server/discover with the
    /// standard header naming its method (SEP-2243 validation).
    async fn discover(app: &Router, bearer: Option<&str>) -> (StatusCode, Value) {
        let mut builder = Request::builder()
            .method(Method::POST)
            .uri("/mcp")
            .header("host", "localhost:4600")
            .header("content-type", "application/json")
            .header("accept", "application/json, text/event-stream")
            .header("mcp-protocol-version", "2026-07-28")
            .header("mcp-method", "server/discover");
        if let Some(bearer) = bearer {
            builder = builder.header("authorization", format!("Bearer {bearer}"));
        }
        let request = builder
            .body(Body::from(
                json!({"jsonrpc": "2.0", "id": 1, "method": "server/discover",
                "params": {"_meta": {
                    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                    "io.modelcontextprotocol/clientCapabilities": {}
                }}})
                .to_string(),
            ))
            .unwrap();
        let response = app.clone().oneshot(request).await.unwrap();
        let status = response.status();
        let bytes = http_body_util::BodyExt::collect(response.into_body())
            .await
            .unwrap()
            .to_bytes();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    async fn tools_list(app: &Router, bearer: &str) -> (StatusCode, Value) {
        mcp(
            app,
            json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}),
            Some(bearer),
        )
        .await
    }

    async fn tools_call(
        app: &Router,
        bearer: &str,
        name: &str,
        arguments: Value,
    ) -> (StatusCode, Value) {
        mcp(
            app,
            json!({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                   "params": {"name": name, "arguments": arguments}}),
            Some(bearer),
        )
        .await
    }

    fn result(body: &Value) -> &Value {
        body.get("result").expect("a JSON-RPC result")
    }

    fn rpc_error(body: &Value) -> (&Value, &Value) {
        let error = body.get("error").expect("a JSON-RPC error");
        (&error["code"], &error["message"])
    }

    fn tool_names(body: &Value) -> Vec<&str> {
        result(body)["tools"]
            .as_array()
            .expect("tools array")
            .iter()
            .map(|tool| tool["name"].as_str().expect("tool name"))
            .collect()
    }

    // ---- fixture: the upstream's answer per token

    /// The full-scope grant list every domain's tools need.
    const ALL_SCOPES: [&str; 6] = [
        "catalog:read",
        "instances:read",
        "instances:write",
        "backups:read",
        "backups:write",
        "wallet:read",
    ];

    fn full_scope_upstream() -> CannedApi {
        testapi::serve(&[
            ("/api/v1/me", 200, me_doc(&ALL_SCOPES)),
            ("/api/v1/organizations", 200, orgs_doc()),
            ("/api/v1/apps", 200, apps_doc()),
            ("/api/v1/apps/wordpress", 200, app_doc()),
            ("/api/v1/apps/wordpress/versions", 200, versions_doc()),
            ("/api/v1/instances", 200, instances_doc()),
            ("/api/v1/instances/i1", 200, instance_doc()),
            ("/api/v1/instances/i1/stop", 200, instance_doc()),
            ("/api/v1/instances/i1/start", 200, instance_doc()),
        ])
    }

    /// /me's document for a PAT caller — top-level meta.scopes carries
    /// the calling token's exact list (#585's shape).
    fn me_doc(scopes: &[&str]) -> String {
        json!({
            "data": {"type": "user", "id": "01H",
                     "attributes": {"email": "me@example.com",
                                    "platform_role": "user", "username": "me"}},
            "meta": {"scopes": scopes}
        })
        .to_string()
    }

    /// The tools a token's scope list leaves visible, in tools/list
    /// order (rmcp sorts by name) — the filter's whole matrix.
    async fn listed_tools(server: &CannedApi, bearer: &str) -> Vec<String> {
        let (_, body) = tools_list(&app(server), bearer).await;
        tool_names(&body).into_iter().map(str::to_owned).collect()
    }

    fn orgs_doc() -> String {
        json!({"data": [
            {"type": "organization", "id": "01JORG1",
             "attributes": {"slug": "personal", "name": "Personal"}}
        ]})
        .to_string()
    }

    fn apps_doc() -> String {
        json!({"data": [
            {"type": "app", "id": "1", "attributes": {"name": "WordPress", "slug": "wordpress"}},
            {"type": "app", "id": "2", "attributes": {"name": "Kavita", "slug": "kavita"}}
        ]})
        .to_string()
    }

    fn app_doc() -> String {
        json!({"data": {"type": "app", "id": "1",
                        "attributes": {"name": "WordPress", "slug": "wordpress",
                                       "tagline": "Blogging", "file_access": true}}})
        .to_string()
    }

    fn instances_doc() -> String {
        json!({"data": [
            {"type": "instance", "id": "i1",
             "attributes": {"name": "web", "slug": "web-a1b2", "status": "running",
                            "always_on": true, "deployed_at": "2026-11-04T21:00:00Z"}}
        ]})
        .to_string()
    }

    fn instance_doc() -> String {
        json!({"data": {"type": "instance", "id": "i1",
                        "attributes": {"name": "web", "slug": "web-a1b2",
                                       "status": "running", "cpu_cores": "0.5"}}})
        .to_string()
    }

    // ---- initialize

    #[tokio::test]
    async fn initialize_with_a_live_token_negotiates_the_newest_handshake_rev() {
        let server = full_scope_upstream();
        let (status, body) = initialize(&app(&server), PAT_FULL).await;
        assert_eq!(status, StatusCode::OK);
        let result = result(&body);
        // The newest rev that still has an initialize handshake (the
        // 2026-07-28 rev replaced the handshake with server/discover).
        assert_eq!(result["protocolVersion"], "2025-11-25");
        assert_eq!(result["serverInfo"]["name"], "FluxVale");
        assert_eq!(result["serverInfo"]["version"], env!("CARGO_PKG_VERSION"));
        assert!(result["capabilities"]["tools"].is_object());
        // The gate rode upstream with the request's bearer.
        assert!(
            server
                .head(0)
                .to_lowercase()
                .contains(&format!("authorization: bearer {PAT_FULL}"))
        );
    }

    #[tokio::test]
    async fn the_stateless_discovery_flow_answers_the_gate_too() {
        // The 2026-07-28 rev: server/discover instead of initialize.
        let server = full_scope_upstream();
        let (_, body) = discover(&app(&server), Some(PAT_FULL)).await;
        let result = result(&body);
        // Server info rides the discovery's _meta; the supported
        // versions span the handshake revs and the stateless one.
        assert_eq!(
            result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"],
            "FluxVale"
        );
        assert!(
            result["supportedVersions"]
                .as_array()
                .expect("versions")
                .len()
                > 1
        );

        // And a dead token refuses discovery at the same gate.
        let dead = testapi::serve(&[("/api/v1/me", 401, unauthorized_doc())]);
        let (_, body) = discover(&app(&dead), Some(PAT_DEAD)).await;
        let (code, message) = rpc_error(&body);
        assert_eq!(code, -32600);
        assert!(
            message.as_str().unwrap().contains("revoke"),
            "message: {message}"
        );
    }

    #[tokio::test]
    async fn initialize_with_a_revoked_token_is_a_protocol_auth_error() {
        let server = testapi::serve(&[("/api/v1/me", 401, unauthorized_doc())]);
        let (status, body) = initialize(&app(&server), PAT_DEAD).await;
        assert_eq!(status, StatusCode::OK); // protocol-level: HTTP 200, JSON-RPC error
        let (code, message) = rpc_error(&body);
        assert_eq!(code, -32600);
        assert!(
            message
                .as_str()
                .unwrap()
                .contains("not signed in or token revoked"),
            "message: {message}"
        );
    }

    #[tokio::test]
    async fn initialize_with_a_forbidden_account_is_a_protocol_auth_error() {
        let server =
            testapi::serve(&[("/api/v1/me", 403, forbidden_doc("this account is refused"))]);
        let (_, body) = initialize(&app(&server), PAT_FULL).await;
        let (code, message) = rpc_error(&body);
        assert_eq!(code, -32600);
        assert!(
            message
                .as_str()
                .unwrap()
                .contains("this account is refused"),
            "message: {message}"
        );
    }

    #[tokio::test]
    async fn initialize_against_a_dead_platform_is_a_verbatim_protocol_error() {
        // Not auth — the platform is unreachable. The gate says so,
        // with the transport line inside.
        let app = crate::build_router("http://127.0.0.1:1");
        let (_, body) = initialize(&app, PAT_FULL).await;
        let (code, message) = rpc_error(&body);
        assert_eq!(code, -32603);
        assert!(
            message
                .as_str()
                .unwrap()
                .contains("the FluxVale API is unavailable"),
            "message: {message}"
        );
    }

    // ---- the /me scope source's fail-loud arms: the one read that
    // answers tools/list either renders the calling token's list or
    // fails the WHOLE list — there is no per-domain hiding anymore
    // (that was the probes' job; the list is exact now).

    #[tokio::test]
    async fn a_me_without_meta_scopes_fails_tools_list_with_its_own_line() {
        // A session-shaped /me answer is a shape mismatch, not an
        // outage — its own error line, never a silent "no tools",
        // never a silent "all tools", never "the API is unavailable".
        let session_shaped = json!({
            "data": {"type": "user", "id": "01H", "attributes": {}}
        })
        .to_string();
        let server = testapi::serve(&[("/api/v1/me", 200, session_shaped)]);
        let (_, body) = tools_list(&app(&server), PAT_FULL).await;
        let (code, message) = rpc_error(&body);
        assert_eq!(code, -32603);
        let message = message.as_str().unwrap();
        assert!(
            message.contains("unexpected /me answer: no meta.scopes"),
            "message: {message}"
        );
        assert!(
            message.contains("not a PAT caller, or the platform predates #585"),
            "message: {message}"
        );
        assert!(
            !message.contains("the FluxVale API is unavailable"),
            "a shape mismatch is not an outage: {message}"
        );
    }

    fn unauthorized_doc() -> String {
        json!({"errors": [{"status": "401", "title": "Unauthorized"}]}).to_string()
    }

    fn forbidden_doc(detail: &str) -> String {
        json!({"errors": [{"status": "403", "title": "Forbidden", "detail": detail}]}).to_string()
    }

    #[tokio::test]
    async fn a_request_without_a_bearer_is_an_http_challenge() {
        let server = full_scope_upstream();
        let (status, body) = mcp(
            &app(&server),
            json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(body, Value::Null); // plain-text challenge, not JSON-RPC
    }

    // ---- tools/list: the scope filter

    #[tokio::test]
    async fn the_2026_rev_lists_tools_with_per_request_metadata() {
        // The 2026-07-28 shape: protocol version + client capabilities
        // ride EVERY request's _meta (the handshake is gone).
        let server = full_scope_upstream();
        let (_, body) = mcp(
            &app(&server),
            json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list",
            "params": {"_meta": {
                "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                "io.modelcontextprotocol/clientCapabilities": {}
            }}}),
            Some(PAT_FULL),
        )
        .await;
        // The full-scope list, same as the handshake rev's — and one
        // upstream read either way (the driver asserts the count in
        // the filter matrix tests above).
        assert_eq!(tool_names(&body).len(), 17);
        assert!(tool_names(&body).contains(&"instances_deploy"));
        assert!(tool_names(&body).contains(&"topup"));
    }

    #[tokio::test]
    async fn a_full_scope_token_sees_all_seventeen_tools() {
        let server = full_scope_upstream();
        assert_eq!(
            listed_tools(&server, PAT_FULL).await,
            [
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
                "topup",
                "wallet_balance",
                "wallet_ledger",
                "wallet_runway",
                "whoami",
            ]
        );
        // W2b's swap: ONE upstream read per tools/list — /me itself.
        assert_eq!(server.head_count(), 1);
        assert!(server.head(0).to_lowercase().starts_with("get /api/v1/me"));
    }

    #[tokio::test]
    async fn a_catalog_only_token_sees_the_apps_pair_and_the_scopeless_pair() {
        let server = testapi::serve(&[("/api/v1/me", 200, me_doc(&["catalog:read"]))]);
        assert_eq!(
            listed_tools(&server, PAT_CATALOG).await,
            ["apps_list", "apps_show", "topup", "whoami"]
        );
    }

    #[tokio::test]
    async fn write_implies_read_on_the_exact_list() {
        // The token's list says instances:write only — the write verbs
        // appear AND the instances reads ride along (write implies
        // read, Scopes.grants?), while every other domain stays hidden.
        let server = testapi::serve(&[
            ("/api/v1/me", 200, me_doc(&["instances:write"])),
            ("/api/v1/instances", 200, instances_doc()),
            ("/api/v1/instances/i1", 200, instance_doc()),
        ]);
        assert_eq!(
            listed_tools(&server, "fvpat_instances_write").await,
            [
                "instances_deploy",
                "instances_destroy",
                "instances_list",
                "instances_start",
                "instances_status",
                "instances_stop",
                "topup",
                "whoami",
            ]
        );
    }

    #[tokio::test]
    async fn a_zero_scope_token_still_gets_the_scopeless_pair() {
        // The protocol stays; tools/list just omits what it can't
        // call. /me renders the empty list for a zero-scope PAT —
        // that is a minted fact, not an absence.
        let server = testapi::serve(&[("/api/v1/me", 200, me_doc(&[]))]);
        assert_eq!(
            listed_tools(&server, "fvpat_no_domains").await,
            ["topup", "whoami"]
        );
    }

    #[tokio::test]
    async fn tools_list_with_a_dead_token_is_a_protocol_auth_error() {
        let server = testapi::serve(&[("/api/v1/me", 401, unauthorized_doc())]);
        let (_, body) = tools_list(&app(&server), PAT_DEAD).await;
        let (code, message) = rpc_error(&body);
        assert_eq!(code, -32600);
        assert!(
            message.as_str().unwrap().contains("revoke"),
            "message: {message}"
        );
    }

    #[tokio::test]
    async fn tools_list_refuses_verbatim_on_a_transient_upstream_failure() {
        let server = testapi::serve(&[("/api/v1/me", 429, r#"{"errors": []}"#.to_string())]);
        let (_, body) = tools_list(&app(&server), PAT_FULL).await;
        let (code, message) = rpc_error(&body);
        assert_eq!(code, -32603);
        assert!(
            message.as_str().unwrap().contains("rate limited"),
            "message: {message}"
        );
    }

    // ---- the five tools' happy paths (structured, flat JSON)

    #[tokio::test]
    async fn whoami_returns_the_flat_identity_row() {
        let server = full_scope_upstream();
        let (_, body) = tools_call(&app(&server), PAT_FULL, "whoami", json!({})).await;
        let structured = &result(&body)["structuredContent"];
        assert_eq!(structured["id"], "01H");
        assert_eq!(structured["email"], "me@example.com");
        assert_eq!(structured["username"], "me");
        assert_eq!(structured["organizations"][0]["id"], "01JORG1");
        assert_eq!(structured["organizations"][0]["slug"], "personal");
        assert_eq!(result(&body)["isError"], false);
    }

    #[tokio::test]
    async fn apps_list_returns_the_catalog_array() {
        let server = full_scope_upstream();
        let (_, body) = tools_call(&app(&server), PAT_FULL, "apps_list", json!({})).await;
        let structured = &result(&body)["structuredContent"];
        // Collections ride a named-key object (the retiring server's
        // shape — the 2025-11-25 schema types structuredContent as an
        // object, so a bare array would break typed clients).
        assert_eq!(structured["apps"][0]["slug"], "wordpress");
        assert_eq!(structured["apps"][0]["id"], "1");
        assert_eq!(structured["apps"][1]["slug"], "kavita");
    }

    #[tokio::test]
    async fn apps_show_returns_one_app_by_slug() {
        let server = full_scope_upstream();
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "apps_show",
            json!({"slug": "wordpress"}),
        )
        .await;
        let structured = &result(&body)["structuredContent"];
        assert_eq!(structured["id"], "1");
        assert_eq!(structured["slug"], "wordpress");
        assert_eq!(structured["tagline"], "Blogging");
    }

    #[tokio::test]
    async fn an_unsafe_slug_is_a_tool_error_without_reaching_upstream() {
        let server = full_scope_upstream();
        let before = server.head_count();
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "apps_show",
            json!({"slug": "../etc/passwd"}),
        )
        .await;
        assert_eq!(result(&body)["isError"], true);
        let text = result(&body)["content"][0]["text"].as_str().unwrap();
        assert_eq!(text, "invalid app slug: ../etc/passwd");
        // The fence refused before any upstream call.
        assert_eq!(server.head_count(), before);
    }

    #[tokio::test]
    async fn instances_list_returns_the_rows() {
        let server = full_scope_upstream();
        let (_, body) = tools_call(&app(&server), PAT_FULL, "instances_list", json!({})).await;
        let structured = &result(&body)["structuredContent"];
        assert_eq!(structured["instances"][0]["id"], "i1");
        assert_eq!(structured["instances"][0]["slug"], "web-a1b2");
        assert_eq!(structured["instances"][0]["status"], "running");
    }

    #[tokio::test]
    async fn instances_status_takes_the_detail_and_verbose_arms() {
        let server = full_scope_upstream();
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "instances_status",
            json!({"id": "i1"}),
        )
        .await;
        let structured = &result(&body)["structuredContent"];
        assert_eq!(structured["id"], "i1");
        assert_eq!(structured["cpu_cores"], "0.5");

        let (_, body) = tools_call(&app(&server), PAT_FULL, "instances_status", json!({})).await;
        let structured = &result(&body)["structuredContent"];
        assert_eq!(structured["instances"][0]["id"], "i1");
    }

    #[tokio::test]
    async fn a_foreign_instance_is_the_friendly_404_line() {
        let server = testapi::serve(&[(
            "/api/v1/instances/ghost",
            404,
            "{\"errors\": []}".to_string(),
        )]);
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "instances_status",
            json!({"id": "ghost"}),
        )
        .await;
        assert_eq!(result(&body)["isError"], true);
        let text = result(&body)["content"][0]["text"].as_str().unwrap();
        assert_eq!(text, "no such instance (or it's not yours)");
    }

    // ---- error surfacing

    #[tokio::test]
    async fn an_api_refusal_passes_through_verbatim_as_a_tool_error() {
        // A filtered-out tool called directly: the platform's 403 IS
        // the enforcement, surfaced word-for-word.
        let server = testapi::serve(&[(
            "/api/v1/apps",
            403,
            forbidden_doc("token lacks the catalog:read scope"),
        )]);
        let (_, body) = tools_call(&app(&server), PAT_CATALOG, "apps_list", json!({})).await;
        assert_eq!(result(&body)["isError"], true);
        let text = result(&body)["content"][0]["text"].as_str().unwrap();
        assert_eq!(text, "403 Forbidden: token lacks the catalog:read scope");
    }

    #[tokio::test]
    async fn a_transient_upstream_failure_is_a_verbatim_tool_error_too() {
        let server = testapi::serve(&[("/api/v1/apps", 500, r#"<html>boom</html>"#.to_string())]);
        let (_, body) = tools_call(&app(&server), PAT_FULL, "apps_list", json!({})).await;
        assert_eq!(result(&body)["isError"], true);
        let text = result(&body)["content"][0]["text"].as_str().unwrap();
        assert_eq!(text, "HTTP 500");
    }

    // ---- the write tools' happy paths (the sequences live in
    // upstream's own tests; these pin the protocol answers)

    fn versions_doc() -> String {
        json!({"data": [
            {"type": "app_version", "id": "v2", "attributes": {"version": "1.2"}},
            {"type": "app_version", "id": "v1", "attributes": {"version": "1.0"}}
        ]})
        .to_string()
    }

    fn deploy_upstream() -> CannedApi {
        let created = json!({"data": {"type": "instance", "id": "i2",
            "attributes": {"id": "i2", "name": "new", "slug": "new-a1", "status": "pending"}}});
        let deployed = json!({"data": {"type": "instance", "id": "i2",
            "attributes": {"id": "i2", "name": "new", "slug": "new-a1", "status": "deploying"}}});
        testapi::serve(&[
            ("GET /api/v1/apps/wordpress", 200, app_doc()),
            ("GET /api/v1/apps/1/versions", 200, versions_doc()),
            ("POST /api/v1/instances", 201, created.to_string()),
            (
                "PATCH /api/v1/instances/i2/deploy",
                200,
                deployed.to_string(),
            ),
        ])
    }

    #[tokio::test]
    async fn deploy_answers_the_deployed_row_in_sequence_order() {
        let server = deploy_upstream();
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "instances_deploy",
            json!({"app": "wordpress", "name": "new"}),
        )
        .await;
        assert_eq!(result(&body)["isError"], false);
        let structured = &result(&body)["structuredContent"];
        assert_eq!(structured["id"], "i2");
        assert_eq!(structured["status"], "deploying");
        // The four-call sequence, in order (app → versions → create →
        // deploy). The create BODY (newest version, given flags) is
        // pinned in upstream's own script-server tests.
        let heads: Vec<String> = (0..4).map(|n| server.head(n).to_lowercase()).collect();
        assert!(
            heads[0].starts_with("get /api/v1/apps/wordpress"),
            "{heads:?}"
        );
        assert!(
            heads[1].starts_with("get /api/v1/apps/1/versions"),
            "{heads:?}"
        );
        assert!(heads[2].starts_with("post /api/v1/instances"), "{heads:?}");
        assert!(
            heads[3].starts_with("patch /api/v1/instances/i2/deploy"),
            "{heads:?}"
        );
    }

    #[tokio::test]
    async fn deploy_refusals_are_tool_errors_with_their_own_words() {
        // Unknown app — the friendly line.
        let server = testapi::serve(&[("GET /api/v1/apps/ghost", 404, r#"{"errors": []}"#.into())]);
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "instances_deploy",
            json!({"app": "ghost", "name": "new"}),
        )
        .await;
        assert_eq!(result(&body)["isError"], true);
        assert_eq!(
            result(&body)["content"][0]["text"],
            "no such app (or it's not yours)"
        );

        // The funded gate, VERBATIM — agents hit the same gate as the
        // UI; the 403 says what it says.
        let gate = json!({"errors": [{"status": "403", "title": "Forbidden",
            "detail": "the org wallet needs funds — top up at /billing/topup"}]});
        let server = testapi::serve(&[
            ("GET /api/v1/apps/wordpress", 200, app_doc()),
            ("GET /api/v1/apps/1/versions", 200, versions_doc()),
            ("POST /api/v1/instances", 403, gate.to_string()),
        ]);
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "instances_deploy",
            json!({"app": "wordpress", "name": "new"}),
        )
        .await;
        assert_eq!(result(&body)["isError"], true);
        assert_eq!(
            result(&body)["content"][0]["text"],
            "403 Forbidden: the org wallet needs funds — top up at /billing/topup"
        );
    }

    #[tokio::test]
    async fn stop_and_start_answer_the_transition_row() {
        let stopped = json!({"data": {"type": "instance", "id": "i1",
            "attributes": {"id": "i1", "name": "web", "slug": "web-a1b2", "status": "stopped"}}});
        let server =
            testapi::serve(&[("PATCH /api/v1/instances/i1/stop", 200, stopped.to_string())]);
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "instances_stop",
            json!({"id": "i1"}),
        )
        .await;
        assert_eq!(result(&body)["structuredContent"]["status"], "stopped");
        assert!(
            server
                .head(0)
                .to_lowercase()
                .starts_with("patch /api/v1/instances/i1/stop")
        );

        let started = json!({"data": {"type": "instance", "id": "i1",
            "attributes": {"id": "i1", "status": "starting"}}});
        let server =
            testapi::serve(&[("PATCH /api/v1/instances/i1/start", 200, started.to_string())]);
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "instances_start",
            json!({"id": "i1"}),
        )
        .await;
        assert_eq!(result(&body)["structuredContent"]["status"], "starting");
    }

    #[tokio::test]
    async fn backups_configure_status_and_run_answer_their_rows() {
        // Configure: the create arm (404 read → POST).
        let setting = json!({"data": {"type": "backup_setting", "id": "set1",
            "attributes": {"id": "set1", "instance_id": "i1", "bucket": "b",
                           "endpoint": "https://e.example", "access_key_id": "KEY",
                           "retention_keep": 7, "enabled": true}}});
        let server = testapi::serve(&[
            (
                "GET /api/v1/instances/i1/backup-setting",
                404,
                r#"{"errors": []}"#.into(),
            ),
            (
                "POST /api/v1/instances/i1/backup-setting",
                201,
                setting.to_string(),
            ),
        ]);
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "backups_configure",
            json!({"instance_id": "i1", "endpoint": "https://e.example",
                    "bucket": "b", "access_key_id": "KEY"}),
        )
        .await;
        assert_eq!(result(&body)["structuredContent"]["bucket"], "b");

        // Status: settings row + latest run.
        let run = json!({"data": [
            {"type": "backup_run", "id": "r9",
             "attributes": {"id": "r9", "kind": "manual", "status": "succeeded",
                            "snapshot_id": "aaaa"}}]});
        let server = testapi::serve(&[
            ("GET /api/v1/instances/i1", 200, instance_doc()),
            (
                "GET /api/v1/instances/i1/backup-setting",
                200,
                setting.to_string(),
            ),
            (
                "GET /api/v1/instances/i1/backup-runs?limit=1",
                200,
                run.to_string(),
            ),
        ]);
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "backups_status",
            json!({"instance_id": "i1"}),
        )
        .await;
        let structured = &result(&body)["structuredContent"];
        assert_eq!(structured["backup_setting"]["id"], "set1");
        assert_eq!(structured["latest_run"]["snapshot_id"], "aaaa");

        // Run: the flat row.
        let started_run = r#"{"id":"r10","kind":"manual","status":"running","instance_id":"i1"}"#;
        let server = testapi::serve(&[(
            "POST /api/v1/instances/i1/backup-runs",
            201,
            started_run.to_string(),
        )]);
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "backups_run",
            json!({"instance_id": "i1"}),
        )
        .await;
        assert_eq!(result(&body)["structuredContent"]["status"], "running");
    }

    #[tokio::test]
    async fn the_wallet_trio_and_topup_answer() {
        let wallet = json!({"data": {"type": "wallet", "id": "w1",
            "attributes": {"id": "w1", "organization_id": "01JORG1",
                           "balance": 400, "paywall_waived": false}}});
        let server = testapi::serve(&[
            (
                "GET /api/v1/organizations/01JORG1/wallet",
                200,
                wallet.to_string(),
            ),
            (
                "GET /api/v1/organizations/01JORG1/wallet/runway",
                200,
                r#"{"balance_cents":400,"burn_micro_cents_per_hour":0,"runway_hours":"infinity"}"#
                    .to_string(),
            ),
        ]);
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "wallet_balance",
            json!({"organization_id": "01JORG1"}),
        )
        .await;
        assert_eq!(result(&body)["structuredContent"]["balance"], 400);

        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "wallet_runway",
            json!({"organization_id": "01JORG1"}),
        )
        .await;
        assert_eq!(
            result(&body)["structuredContent"]["runway_hours"],
            "infinity"
        );

        // Ledger: the keyset page with its next cursor.
        let ledger = json!({
            "data": [{"type": "ledger_entry", "id": "e2",
                      "attributes": {"id": "e2", "amount": -5, "type": "usage"}}],
            "links": {"next":
                "/api/v1/wallets/w1/ledger-entries?page[limit]=25&sort=-id&page[after]=Q1VCUw"}
        });
        let server = testapi::serve(&[
            (
                "GET /api/v1/organizations/01JORG1/wallet",
                200,
                wallet.to_string(),
            ),
            (
                "GET /api/v1/wallets/w1/ledger-entries?page[limit]=25&sort=-id",
                200,
                ledger.to_string(),
            ),
        ]);
        let (_, body) = tools_call(
            &app(&server),
            PAT_FULL,
            "wallet_ledger",
            json!({"organization_id": "01JORG1"}),
        )
        .await;
        let structured = &result(&body)["structuredContent"];
        assert_eq!(structured["entries"][0]["id"], "e2");
        assert_eq!(structured["next_cursor"], "Q1VCUw");

        // Topup: the URL, and no upstream call at all.
        let bare = testapi::serve(&[]);
        let (_, body) = tools_call(&app(&bare), PAT_FULL, "topup", json!({})).await;
        assert_eq!(
            result(&body)["structuredContent"]["url"],
            format!("{}/billing/topup", bare.base_url)
        );
        assert_eq!(bare.head_count(), 0);
    }

    // ---- the elicitation gate (destroy + restore): the MRTR flow
    // over the 2026-07-28 stateless rev, and the honest refusals.

    /// A tools/call POST in the 2026-07-28 stateless shape: the
    /// per-request _meta names the rev and the client's capabilities
    /// (rmcp's `client_capabilities()` reads exactly these); a confirm
    /// round's echo — inputResponses + requestState — rides the
    /// params' top level.
    async fn stateless_tools_call(
        app: &Router,
        bearer: &str,
        name: &str,
        arguments: Value,
        elicitation: bool,
        confirm: Option<(&Value, &str)>,
    ) -> (StatusCode, Value) {
        let mut params = json!({
            "name": name,
            "arguments": arguments,
            "_meta": {
                "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                "io.modelcontextprotocol/clientCapabilities": if elicitation {
                    json!({"elicitation": {}})
                } else {
                    json!({})
                }
            }
        });
        if let Some((responses, state)) = confirm {
            params["inputResponses"] = responses.clone();
            params["requestState"] = json!(state);
        }
        mcp(
            app,
            json!({"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": params}),
            Some(bearer),
        )
        .await
    }

    const PAT_CAPABLE: &str = "fvpat_elicitation_client";

    /// The yes/no confirm response under the `confirm` key.
    fn confirm_response(answer: &str) -> Value {
        json!({"confirm": {"action": "accept", "content": {"confirm": answer}}})
    }

    /// The destructive pair's upstream: /me with the full grant (the
    /// first-round scope check reads it before the resolve), the
    /// resolve read, and the DELETE.
    fn destroy_upstream() -> CannedApi {
        let deleted = r#"{"id":"i1","name":"web","slug":"web-a1b2","status":"deleting"}"#;
        testapi::serve(&[
            ("/api/v1/me", 200, me_doc(&ALL_SCOPES)),
            ("GET /api/v1/instances/i1", 200, instance_doc()),
            ("DELETE /api/v1/instances/i1", 200, deleted.to_string()),
        ])
    }

    #[tokio::test]
    async fn a_client_without_the_capability_gets_the_honest_error_and_nothing_runs() {
        // The 2025-11-25 handshake-rev shape (no per-request
        // capabilities exist there): the tool refuses, the verb never
        // runs — never a silent no-op, never a protocol crash. Both
        // destructive tools, zero upstream calls: the capability
        // check precedes even the scope read.
        let restore_args = json!({"instance_id": "i1", "backup_run_id": RUN_ID});
        for (tool, arguments) in [
            ("instances_destroy", json!({"id": "i1"})),
            ("backups_restore", restore_args.clone()),
        ] {
            let server = destroy_upstream();
            let (_, body) = tools_call(&app(&server), PAT_FULL, tool, arguments.clone()).await;
            assert_eq!(result(&body)["isError"], true, "tool: {tool}");
            let text = result(&body)["content"][0]["text"].as_str().unwrap();
            assert!(
                text.contains("cannot confirm destructive actions"),
                "tool: {tool}, text: {text}"
            );
            assert!(text.contains(tool), "tool: {tool}, text: {text}");
            assert!(text.contains("panel"), "tool: {tool}, text: {text}");
            assert_eq!(
                server.head_count(),
                0,
                "tool: {tool} — no upstream call may go out"
            );

            // Same posture on the 2026-07-28 rev without the
            // capability declared: the stateless rev carries
            // capabilities per request, and this client declares none.
            let server = destroy_upstream();
            let (_, body) =
                stateless_tools_call(&app(&server), PAT_FULL, tool, arguments, false, None).await;
            assert_eq!(result(&body)["isError"], true, "tool: {tool}");
            assert!(
                result(&body)["content"][0]["text"]
                    .as_str()
                    .unwrap()
                    .contains("cannot confirm destructive actions"),
                "tool: {tool}"
            );
            assert_eq!(server.head_count(), 0, "tool: {tool}");
        }
    }

    #[tokio::test]
    async fn a_capable_clients_first_destroy_round_is_the_question() {
        let server = destroy_upstream();
        let (_, body) = stateless_tools_call(
            &app(&server),
            PAT_CAPABLE,
            "instances_destroy",
            json!({"id": "i1"}),
            true,
            None,
        )
        .await;
        // The intermediate result: input_required, the confirm
        // question naming the instance (name/slug — the Elixir
        // server's copy), and the sealed state.
        assert_eq!(result(&body)["resultType"], "input_required");
        let question = &result(&body)["inputRequests"]["confirm"];
        assert_eq!(question["method"], "elicitation/create");
        let message = question["params"]["message"].as_str().unwrap();
        assert!(
            message.contains("destroy instance web (web-a1b2)"),
            "message: {message}"
        );
        assert!(
            message.contains("All data is deleted"),
            "message: {message}"
        );
        assert!(
            result(&body)["requestState"]
                .as_str()
                .is_some_and(|s| !s.is_empty()),
            "the sealed state rides: {}",
            result(&body)
        );
        // Only the scope read and the resolve went out — the DELETE
        // waits for the yes. Order pinned: the scope check reads /me
        // BEFORE the resolve (Elixir's require_scope → resolve → ask).
        assert_eq!(server.head_count(), 2);
        assert!(
            server.head(0).to_lowercase().starts_with("get /api/v1/me"),
            "the scope check reads /me first"
        );
        assert!(
            server
                .head(1)
                .to_lowercase()
                .starts_with("get /api/v1/instances/i1")
        );
    }

    #[tokio::test]
    async fn a_read_only_token_gets_the_scope_refusal_before_the_question() {
        // Elixir parity (require_scope before ask_confirm): the
        // domain write scope is checked BEFORE the human is asked —
        // a read-only token never sees a confirm question, and the
        // instance resolve never even runs (one /me read, then the
        // refusal). The confirm-round retry path doesn't re-check.
        let arms = [
            (
                "instances_destroy",
                "instances:read",
                "instances:write",
                json!({"id": "i1"}),
            ),
            (
                "backups_restore",
                "backups:read",
                "backups:write",
                json!({"instance_id": "i1", "backup_run_id": RUN_ID}),
            ),
        ];
        for (tool, granted, required, arguments) in arms {
            let server = testapi::serve(&[
                ("/api/v1/me", 200, me_doc(&[granted])),
                ("GET /api/v1/instances/i1", 200, instance_doc()),
            ]);
            let (_, body) =
                stateless_tools_call(&app(&server), PAT_CAPABLE, tool, arguments, true, None).await;
            assert_eq!(result(&body)["isError"], true, "tool: {tool}");
            assert_eq!(
                result(&body)["content"][0]["text"],
                format!("this token lacks the {required} scope"),
                "tool: {tool}"
            );
            // The /me read alone — no resolve, no question.
            assert_eq!(server.head_count(), 1, "tool: {tool}");
            assert!(
                result(&body)["inputRequests"].is_null(),
                "tool: {tool} — never a question"
            );
        }
    }

    #[tokio::test]
    async fn a_yes_round_runs_the_delete() {
        let server = destroy_upstream();
        let app = app(&server);
        let (_, first) = stateless_tools_call(
            &app,
            PAT_CAPABLE,
            "instances_destroy",
            json!({"id": "i1"}),
            true,
            None,
        )
        .await;
        let sealed = result(&first)["requestState"].as_str().unwrap().to_string();
        let yes = confirm_response("yes");

        let (_, body) = stateless_tools_call(
            &app,
            PAT_CAPABLE,
            "instances_destroy",
            json!({"id": "i1"}),
            true,
            Some((&yes, &sealed)),
        )
        .await;
        assert_eq!(result(&body)["isError"], false);
        assert_eq!(result(&body)["structuredContent"]["status"], "deleting");
        // The DELETE went out on the confirm round (after the first
        // round's /me + resolve).
        assert!(
            server
                .head(2)
                .to_lowercase()
                .starts_with("delete /api/v1/instances/i1")
        );
    }

    #[tokio::test]
    async fn a_no_or_decline_cancels_without_touching_anything() {
        for answer in [
            confirm_response("no"),
            json!({"confirm": {"action": "decline"}}),
            json!({"confirm": {"action": "cancel"}}),
        ] {
            let server = destroy_upstream();
            let app = app(&server);
            let (_, first) = stateless_tools_call(
                &app,
                PAT_CAPABLE,
                "instances_destroy",
                json!({"id": "i1"}),
                true,
                None,
            )
            .await;
            let sealed = result(&first)["requestState"].as_str().unwrap().to_string();

            let (_, body) = stateless_tools_call(
                &app,
                PAT_CAPABLE,
                "instances_destroy",
                json!({"id": "i1"}),
                true,
                Some((&answer, &sealed)),
            )
            .await;
            assert_eq!(result(&body)["isError"], false);
            assert_eq!(
                result(&body)["content"][0]["text"],
                "cancelled. Nothing was changed"
            );
            // The scope read + resolve alone — the DELETE never went
            // out.
            assert_eq!(server.head_count(), 2, "answer: {answer}");
        }
    }

    #[tokio::test]
    async fn a_resent_confirm_cannot_steer_a_different_instance() {
        // The question named i1; the retry's arguments claim i2. The
        // target that runs is the sealed one — i1.
        let deleted = r#"{"id":"i1","name":"web","slug":"web-a1b2","status":"deleting"}"#;
        let server = testapi::serve(&[
            ("/api/v1/me", 200, me_doc(&ALL_SCOPES)),
            ("GET /api/v1/instances/i1", 200, instance_doc()),
            ("DELETE /api/v1/instances/i1", 200, deleted.to_string()),
            // i2 exists on the read side only — a DELETE to i2 would
            // land on the 404 default arm and fail loudly.
            ("GET /api/v1/instances/i2", 200, instance_doc()),
        ]);
        let app = app(&server);
        let (_, first) = stateless_tools_call(
            &app,
            PAT_CAPABLE,
            "instances_destroy",
            json!({"id": "i1"}),
            true,
            None,
        )
        .await;
        let sealed = result(&first)["requestState"].as_str().unwrap().to_string();

        let (_, body) = stateless_tools_call(
            &app,
            PAT_CAPABLE,
            "instances_destroy",
            json!({"id": "i2"}), // the steering attempt
            true,
            Some((&confirm_response("yes"), &sealed)),
        )
        .await;
        assert_eq!(result(&body)["structuredContent"]["id"], "i1");
        assert!(
            server
                .head(2)
                .to_lowercase()
                .starts_with("delete /api/v1/instances/i1"),
            "the target that runs is the sealed one, not the re-sent id"
        );
    }

    #[tokio::test]
    async fn a_tampered_or_cross_tool_or_cross_token_seal_refuses() {
        let server = destroy_upstream();
        let router = app(&server);
        let (_, first) = stateless_tools_call(
            &router,
            PAT_CAPABLE,
            "instances_destroy",
            json!({"id": "i1"}),
            true,
            None,
        )
        .await;
        let sealed = result(&first)["requestState"].as_str().unwrap().to_string();

        // Tampered state: integrity fails, one honest line.
        let tampered = format!("{}x", &sealed[..sealed.len() - 1]);
        let (_, body) = stateless_tools_call(
            &router,
            PAT_CAPABLE,
            "instances_destroy",
            json!({"id": "i1"}),
            true,
            Some((&confirm_response("yes"), &tampered)),
        )
        .await;
        assert_eq!(result(&body)["isError"], true);
        assert!(
            result(&body)["content"][0]["text"]
                .as_str()
                .unwrap()
                .contains("invalid, expired, or from another token")
        );

        // A DIFFERENT token cannot spend this client's seal.
        let (_, body) = stateless_tools_call(
            &router,
            "fvpat_someone_else",
            "instances_destroy",
            json!({"id": "i1"}),
            true,
            Some((&confirm_response("yes"), &sealed)),
        )
        .await;
        assert_eq!(result(&body)["isError"], true);

        // A seal from the OTHER destructive tool never opens here.
        let restore_server = testapi::serve(&[
            ("/api/v1/me", 200, me_doc(&ALL_SCOPES)),
            ("GET /api/v1/instances/i1", 200, instance_doc()),
        ]);
        let (_, restore_first) = stateless_tools_call(
            &app(&restore_server),
            PAT_CAPABLE,
            "backups_restore",
            json!({"instance_id": "i1", "backup_run_id": "11111111-2222-3333-4444-555555555555"}),
            true,
            None,
        )
        .await;
        let restore_seal = result(&restore_first)["requestState"].as_str().unwrap();
        let (_, body) = stateless_tools_call(
            &router,
            PAT_CAPABLE,
            "instances_destroy",
            json!({"id": "i1"}),
            true,
            Some((&confirm_response("yes"), restore_seal)),
        )
        .await;
        assert_eq!(result(&body)["isError"], true);
        assert!(
            result(&body)["content"][0]["text"]
                .as_str()
                .unwrap()
                .contains("another action")
        );
        // No DELETE went out in any of these arms — the first round's
        // /me + resolve are the only calls.
        assert_eq!(server.head_count(), 2);
    }

    #[tokio::test]
    async fn restore_refuses_a_tampered_or_destroy_minted_seal() {
        // The cross-tool DIRECTION the destroy test doesn't pin: a
        // DESTROY-minted seal presented to backups_restore never
        // opens — and neither does a tampered one. Zero upstream
        // calls on these rounds.
        let restore_server = testapi::serve(&[
            ("/api/v1/me", 200, me_doc(&ALL_SCOPES)),
            ("GET /api/v1/instances/i1", 200, instance_doc()),
        ]);
        let restore_router = app(&restore_server);
        let arguments = json!({"instance_id": "i1", "backup_run_id": RUN_ID});

        // A destroy seal, minted for the same token.
        let (_, destroy_first) = stateless_tools_call(
            &app(&destroy_upstream()),
            PAT_CAPABLE,
            "instances_destroy",
            json!({"id": "i1"}),
            true,
            None,
        )
        .await;
        let destroy_seal = result(&destroy_first)["requestState"]
            .as_str()
            .unwrap()
            .to_string();

        // Tampered: integrity fails — the single INVALID_SEAL line.
        let tampered = format!("{}x", &destroy_seal[..destroy_seal.len() - 1]);
        let (_, body) = stateless_tools_call(
            &restore_router,
            PAT_CAPABLE,
            "backups_restore",
            arguments.clone(),
            true,
            Some((&confirm_response("yes"), &tampered)),
        )
        .await;
        assert_eq!(result(&body)["isError"], true);
        assert!(
            result(&body)["content"][0]["text"]
                .as_str()
                .unwrap()
                .contains("invalid, expired, or from another token")
        );

        // Untampered but the other tool's: the WRONG_TOOL line.
        let (_, body) = stateless_tools_call(
            &restore_router,
            PAT_CAPABLE,
            "backups_restore",
            arguments,
            true,
            Some((&confirm_response("yes"), &destroy_seal)),
        )
        .await;
        assert_eq!(result(&body)["isError"], true);
        assert!(
            result(&body)["content"][0]["text"]
                .as_str()
                .unwrap()
                .contains("another action")
        );
        // Neither confirm round reached the wire — the restore never
        // went out.
        assert_eq!(restore_server.head_count(), 0);
    }

    #[tokio::test]
    async fn a_foreign_instance_404s_before_the_question_on_both_destructive_tools() {
        // The not-found posture surfaces BEFORE the confirm round —
        // no question for an instance that isn't the caller's. The
        // scope check still reads /me first, so it's in the fixture.
        let arguments = [
            ("instances_destroy", json!({"id": "ghost"})),
            (
                "backups_restore",
                json!({"instance_id": "ghost", "backup_run_id": RUN_ID}),
            ),
        ];
        for (tool, arguments) in arguments {
            let server = testapi::serve(&[
                ("/api/v1/me", 200, me_doc(&ALL_SCOPES)),
                (
                    "GET /api/v1/instances/ghost",
                    404,
                    r#"{"errors": []}"#.into(),
                ),
            ]);
            let (_, body) =
                stateless_tools_call(&app(&server), PAT_CAPABLE, tool, arguments, true, None).await;
            assert_eq!(result(&body)["isError"], true, "tool: {tool}");
            assert_eq!(
                result(&body)["content"][0]["text"],
                "no such instance (or it's not yours)",
                "tool: {tool}"
            );
            // /me (scope) then the failed resolve — no question.
            assert_eq!(server.head_count(), 2, "tool: {tool}");
        }
    }

    #[tokio::test]
    async fn backups_status_surfaces_a_broken_settings_read_verbatim() {
        // A non-404 failure on the settings read (an upstream 500)
        // surfaces the API's own words — never a silent "not
        // configured" (that answer belongs to 404 alone).
        let server = testapi::serve(&[
            ("GET /api/v1/instances/i1", 200, instance_doc()),
            (
                "GET /api/v1/instances/i1/backup-setting",
                500,
                r#"{"errors": [{"detail": "the settings read exploded"}]}"#.into(),
            ),
        ]);
        let (_, body) = stateless_tools_call(
            &app(&server),
            PAT_CAPABLE,
            "backups_status",
            json!({"instance_id": "i1"}),
            true,
            None,
        )
        .await;
        assert_eq!(result(&body)["isError"], true);
        let text = result(&body)["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("the settings read exploded"), "text: {text}");
    }

    #[tokio::test]
    async fn a_row_without_name_fields_falls_back_to_the_id_in_the_question() {
        // The question always names SOMETHING — a row without name or
        // slug (an unexpected shape) names the id twice rather than
        // panic or blank.
        let bare = json!({"data": {"type": "instance", "id": "i1",
            "attributes": {"status": "running"}}});
        let server = testapi::serve(&[
            ("/api/v1/me", 200, me_doc(&ALL_SCOPES)),
            ("GET /api/v1/instances/i1", 200, bare.to_string()),
        ]);
        let (_, body) = stateless_tools_call(
            &app(&server),
            PAT_CAPABLE,
            "instances_destroy",
            json!({"id": "i1"}),
            true,
            None,
        )
        .await;
        let message = result(&body)["inputRequests"]["confirm"]["params"]["message"]
            .as_str()
            .unwrap();
        assert_eq!(
            message,
            "destroy instance i1 (i1). All data is deleted. Confirm?"
        );
    }

    const RUN_ID: &str = "11111111-2222-3333-4444-555555555555";

    #[tokio::test]
    async fn restores_run_id_fence_refuses_before_asking() {
        // The Elixir schema's uuid pattern: a garbage run id gets its
        // refusal BEFORE the question — a confirm round trip for an
        // unrestorable id is wasted work for the human.
        let server = testapi::serve(&[]);
        let (_, body) = stateless_tools_call(
            &app(&server),
            PAT_CAPABLE,
            "backups_restore",
            json!({"instance_id": "i1", "backup_run_id": "r9"}),
            true,
            None,
        )
        .await;
        assert_eq!(result(&body)["isError"], true);
        let text = result(&body)["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("invalid backup_run_id r9"), "text: {text}");
        assert_eq!(server.head_count(), 0);
    }

    #[tokio::test]
    async fn restore_asks_then_runs_or_cancels_on_the_answer() {
        let restored = r#"{"id":"r10","kind":"restore","status":"running","instance_id":"i1","restored_from":"running"}"#;
        let server = testapi::serve(&[
            ("/api/v1/me", 200, me_doc(&ALL_SCOPES)),
            ("GET /api/v1/instances/i1", 200, instance_doc()),
            (
                &format!("POST /api/v1/instances/i1/backup-runs/{RUN_ID}/restore"),
                201,
                restored.to_string(),
            ),
        ]);
        let app = app(&server);

        // The question names the run AND the instance.
        let (_, first) = stateless_tools_call(
            &app,
            PAT_CAPABLE,
            "backups_restore",
            json!({"instance_id": "i1", "backup_run_id": RUN_ID}),
            true,
            None,
        )
        .await;
        assert_eq!(result(&first)["resultType"], "input_required");
        let message = result(&first)["inputRequests"]["confirm"]["params"]["message"]
            .as_str()
            .unwrap();
        assert!(
            message.contains(&format!(
                "restore snapshot {RUN_ID} onto instance web (web-a1b2)"
            )),
            "message: {message}"
        );
        assert!(message.contains("OVERWRITTEN"), "message: {message}");
        assert_eq!(
            server.head_count(),
            2,
            "the scope read and the resolve only — the restore never went out yet"
        );

        // Yes: the restore POST rides.
        let sealed = result(&first)["requestState"].as_str().unwrap().to_string();
        let (_, body) = stateless_tools_call(
            &app,
            PAT_CAPABLE,
            "backups_restore",
            json!({"instance_id": "i1", "backup_run_id": RUN_ID}),
            true,
            Some((&confirm_response("yes"), &sealed)),
        )
        .await;
        assert_eq!(result(&body)["structuredContent"]["kind"], "restore");
        assert!(server.head(2).to_lowercase().starts_with(&format!(
            "post /api/v1/instances/i1/backup-runs/{run_id}/restore",
            run_id = RUN_ID.to_lowercase()
        )),);

        // No: nothing was changed.
        let (_, first) = stateless_tools_call(
            &app,
            PAT_CAPABLE,
            "backups_restore",
            json!({"instance_id": "i1", "backup_run_id": RUN_ID}),
            true,
            None,
        )
        .await;
        let sealed = result(&first)["requestState"].as_str().unwrap().to_string();
        let (_, body) = stateless_tools_call(
            &app,
            PAT_CAPABLE,
            "backups_restore",
            json!({"instance_id": "i1", "backup_run_id": RUN_ID}),
            true,
            Some((&confirm_response("no"), &sealed)),
        )
        .await;
        assert_eq!(
            result(&body)["content"][0]["text"],
            "cancelled. Nothing was changed"
        );
        assert_eq!(
            server.head_count(),
            5,
            "two scope+resolve rounds and one restore — the no-arm adds nothing"
        );
    }
}
