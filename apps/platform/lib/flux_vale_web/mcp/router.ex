defmodule FluxValeWeb.MCP.Router do
  @moduledoc """
  FluxVale's MCP server: tools over your FluxVale account — reads plus
  the write tools of every domain — authenticated with your personal
  access token (PAT).

  What this server exposes:

  - **Instances** — the apps you deployed (`list_instances`,
    `get_instance`), with lifecycle status and allocation — and their
    lifecycle writes: `deploy_instance`, `stop_instance`,
    `start_instance`, `set_instance_always_on`, `set_instance_exposure`,
    plus the destructive `destroy_instance`.
  - **Backups** — an instance's backup settings (`get_backup_settings`,
    `configure_backups`) and its run history (`list_backup_runs`), the
    manual `run_backup`, and the destructive `restore_backup`.
  - **Access** — your organization's private-access gateway
    (`get_gateway`, `create_gateway`, `resume_gateway`) and the
    attach/detach pair that puts private instances on your tailnet.
  - **Billing** — wallet balance plus projected runway (`get_wallet`)
    and the ledger history (`list_ledger_entries`).
  - **Catalog** — the deployable app catalog (`list_apps`).
  - **`whoami`** — the identity your token carries and its scopes.

  Write tools require the domain's `:write` scope (`write` implies
  `read`). The destructive pair — `restore_backup` (OVERWRITES the
  instance's volume with the snapshot) and `destroy_instance` (deletes
  the volume data and all its Kubernetes resources) — confirm before
  acting: the first call comes back as an `input_required` result
  carrying a question with a yes/no answer. The action only runs after
  your client answers "yes"; "no", declining, or dropping the question
  changes nothing. Tools are scope-filtered per token: `tools/list`
  only ever offers what the token's scopes cover (a read-only token
  never sees a write tool), and each handler re-checks the scope
  before acting.

  Policies are enforced exactly as over the HTTP API: you only ever
  see your own organization's data.
  """

  use Phantom.Router,
    name: "FluxVale",
    # vsn via otp_app — the supported path (use-args are macro AST, so
    # `vsn: Application.spec(...)` would be to_string'd unevaluated).
    # Resolves to the app's "0.1.0".
    otp_app: :flux_vale,
    instructions: @moduledoc,
    # MCP 2026-07-28's stateless `requestState` blob (elicitation,
    # slice 2) encrypts with the endpoint's key — resolved lazily per
    # call, so dev/test/prod each read their own configured value.
    secret_key_base: {FluxValeWeb.Endpoint, :config, [:secret_key_base]},
    request_state_salt: "fluxvale mcp request_state v1"

  alias FluxVale.Api.Scopes
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Wallet
  alias FluxVale.Catalog.App
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Ops.AccessRules

  # The tool catalog's scope gate (#361): tool name => the required
  # scope, `:any` for scopeless reads (the /api/v1 /me posture). The
  # same map feeds BOTH filtering directions: connect/2 intersects it
  # with the token's scopes for `Phantom.Session.allow_tools/2`
  # (tools/list omits what the token lacks), and every handler
  # re-checks it before dispatch — a filtered-out tool called
  # directly still refuses (defense in depth; phantom's allowlist
  # already makes such a call unresolvable). The write tools carry the
  # same scopes the /api/v1 write routes do (Scopes.grants? treats
  # `write` as implying `read`).
  @tool_scopes %{
    "whoami" => :any,
    "list_instances" => "instances:read",
    "get_instance" => "instances:read",
    "deploy_instance" => "instances:write",
    "stop_instance" => "instances:write",
    "start_instance" => "instances:write",
    "set_instance_always_on" => "instances:write",
    "set_instance_exposure" => "instances:write",
    "destroy_instance" => "instances:write",
    "list_apps" => "catalog:read",
    "get_backup_settings" => "backups:read",
    "list_backup_runs" => "backups:read",
    "configure_backups" => "backups:write",
    "run_backup" => "backups:write",
    "restore_backup" => "backups:write",
    "get_gateway" => "gateways:read",
    "attach_instance" => "gateways:write",
    "detach_instance" => "gateways:write",
    "create_gateway" => "gateways:write",
    "resume_gateway" => "gateways:write",
    "get_wallet" => "wallet:read",
    "list_ledger_entries" => "wallet:read"
  }

  # #361 slice 2: the confirmation elicit's one schema — the two
  # destructive tools share it; the question message is the per-tool
  # half.
  @confirm_schema [
    %{
      name: "confirm",
      type: :enum,
      enum: ["yes", "no"],
      required: true,
      title: "Confirm",
      description: "yes runs it; no cancels without changing anything"
    }
  ]

  # #361 slice 2: the create_gateway/resume_gateway descriptions carry
  # the same config figure the create action pins, so the agent sees
  # the cost before it commits. Compile-time read on purpose: the rate
  # is a static config value today; if it ever moves to runtime config,
  # move this read with it (the description would otherwise drift from
  # the pinned price).
  @gateway_cents Application.compile_env(:flux_vale, :access_gateway)[:monthly_cents]

  # $X.YZ from the config's cents — interpolated at compile time.
  @gateway_remainder_string @gateway_cents
                            |> rem(100)
                            |> Integer.to_string()
                            |> String.pad_leading(2, "0")

  @gateway_rate String.trim("""
                $#{div(@gateway_cents, 100)}.#{@gateway_remainder_string} a month
                """)

  # The #265 exposure enum — the wire values are the type's own values,
  # so the tool's enum can never drift from the resource's.
  @exposures Enum.map(FluxVale.Infrastructure.Types.InstanceExposure.values(), &to_string/1)

  # The wire field sets — the API routes' default_fields are the
  # contract (ADR-0019 §1); `hide_fields` removals (env_vars,
  # status_message) are structurally absent here, and the private
  # attributes (metering anchors, failure_reason, carryover, claims)
  # never ride any route's field list.
  @instance_list_fields [
    :name,
    :slug,
    :namespace,
    :status,
    :exposure,
    :always_on,
    :deployed_at
  ]

  @instance_detail_fields [
    :name,
    :slug,
    :namespace,
    :status,
    :exposure,
    :always_on,
    :image,
    :port,
    :healthcheck_path,
    :storage_mount_path,
    :file_access,
    :cpu_cores,
    :memory_mb,
    :storage_gb,
    :deployed_at
  ]

  @app_fields [
    :name,
    :slug,
    :tagline,
    :description,
    :icon_url,
    :source_url,
    :docs_url,
    :file_access
  ]

  @backup_setting_fields [
    :instance_id,
    :endpoint,
    :bucket,
    :prefix,
    :access_key_id,
    :retention_keep,
    :enabled
  ]

  # The configure_backups param keys — exactly the row's accepted
  # fields (the secret key is not part of this surface, like the HTTP
  # route's). String keys: the params are the wire's.
  @backup_param_fields ~w(endpoint bucket prefix access_key_id retention_keep enabled)

  @backup_run_fields [
    :instance_id,
    :kind,
    :status,
    :snapshot_id,
    :bytes_processed,
    :bytes_added,
    :bytes_restored,
    :error_summary,
    :restored_from,
    :started_at,
    :finished_at
  ]

  @gateway_fields [
    :organization_id,
    :hostname,
    :tailnet_domain,
    :provider,
    :state,
    :status_message,
    :monthly_cents,
    :provisioned_at
  ]

  @ledger_fields [
    :wallet_id,
    :amount,
    :type,
    :reason,
    :idempotency_key,
    :reverses_id,
    :billing_country,
    :billing_state,
    :applied_rate,
    :tax_cents,
    :subject,
    :reverse_charge?
  ]

  # The AccessRule denial's one message — user-level, not token-level.
  @denial_message "this account is not allowed to use FluxVale"

  @legacy_refusal "this MCP endpoint serves only the stateless protocol rev 2026-07-28"

  @impl Phantom.Router
  def connect(session, conn) do
    user = conn.assigns[:current_user]
    pat = conn.assigns[:api_pat]

    cond do
      # No live PAT: the protocol-correct challenge. `Phantom.Plug`
      # renders the map as a WWW-Authenticate header (RFC 9728).
      is_nil(pat) ->
        {:unauthorized, %{method: "Bearer"}}

      # Authenticate severed the user at the boundary (AccessRules
      # denied the address, the token row survives) — the account is
      # refused, not the credential.
      is_nil(user) ->
        {:forbidden, @denial_message}

      # The same function Authenticate enforces at the boundary: a rule
      # that lands between its check and this call still refuses here
      # (the check re-reads through Authenticate's own posture).
      AccessRules.ensure_allowed_user(user) != :ok ->
        {:forbidden, @denial_message}

      # The stateless rev only. phantom's flag is set from the same
      # header/body signals its dispatch uses; a legacy client's
      # initialize/session flow contradicts the stateless posture
      # (#361's settled decision) and is refused after auth.
      not conn.private.phantom.modern ->
        {:forbidden, @legacy_refusal}

      true ->
        {:ok, grant_tools(session, user, pat)}
    end
  end

  # phantom's `otp_app:` vsn resolves through `Application.spec` at
  # ROUTER-COMPILE time, where the app being compiled isn't loaded
  # yet — the advertised version came out as "". Read the live spec
  # per initialize instead (same source as `/health`'s version).
  @impl Phantom.Router
  def server_info(_session) do
    {:ok, %{name: "FluxVale", version: to_string(Application.spec(:flux_vale, :vsn))}}
  end

  # The session's scope filter: tools/list offers (and tools/call
  # resolves) only the tools the token's scopes cover.
  defp grant_tools(session, user, pat) do
    allowed =
      @tool_scopes
      |> Enum.filter(fn {_tool, scope} -> scope_granted?(pat, scope) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    session
    |> Phantom.Session.allow_tools(allowed)
    |> assign_session_actor(user, pat)
  end

  defp assign_session_actor(session, user, pat) do
    # request_state_principal binds every encrypted requestState blob
    # to this user (Phantom.RequestState.binding/2): a stolen blob
    # cannot be resumed under anyone else's token.
    %{
      session
      | assigns:
          Map.merge(session.assigns, %{user: user, pat: pat, request_state_principal: user.id})
    }
  end

  defp scope_granted?(_pat, :any), do: true
  defp scope_granted?(pat, required), do: Scopes.grants?(pat.scopes, required)

  # --- the read tools ------------------------------------------------

  @description """
  The identity this token carries: user id, email, platform role, and
  the exact scope list the token was minted with. Use it first to
  learn what the token may do — tools outside the scopes never appear
  in tools/list.
  """
  tool :whoami, read_only: true do
  end

  @spec whoami(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def whoami(_params, session) do
    with :ok <- require_scope(session, :any) do
      %{user: actor, pat: pat} = session.assigns

      # An expr-calculation load on the actor's own struct — no policy
      # query behind it. A failure here is data corruption; phantom
      # renders the crash as a protocol-internal error.
      user = Ash.load!(actor, :primary_email, actor: actor, authorize?: true)

      attributes = %{
        email: user.primary_email,
        platform_role: user.platform_role,
        scopes: pat.scopes
      }

      response = row(user, "user", attributes)
      {:reply, Phantom.Tool.structured(response), session}
    end
  end

  @description """
  The caller's own instances, newest first — one entry per deployed
  app: id, name, slug, namespace, lifecycle status, exposure,
  always-on flag, deployed-at. Follow up with `get_instance` for the
  full detail of one row.
  """
  tool :list_instances, read_only: true do
  end

  @spec list_instances(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def list_instances(_params, session) do
    with :ok <- require_scope(session, "instances:read"),
         {:ok, instances} <- instance_page(session.assigns.user) do
      rows = %{instances: Enum.map(instances, &row(&1, "instance", @instance_list_fields))}
      {:reply, Phantom.Tool.structured(rows), session}
    else
      other -> tool_error(session, other)
    end
  end

  # The description promises newest first; the action leaves the sort
  # to callers (the panel adds its own) — the tool pins it: uuidv7 id
  # desc is the creation order.
  defp instance_page(user) do
    Instance
    |> Ash.Query.for_read(:list_for_actor, %{}, actor: user, authorize?: true)
    |> Ash.Query.sort(id: :desc)
    |> Ash.read()
  end

  @description """
  One instance's full detail by id: identity (name/slug/namespace),
  lifecycle status, exposure, allocation (cpu/memory/storage), image,
  port, healthcheck path, storage mount, file-access flag, deployed-at.
  Environment variables and the technical status trail are never
  returned. Errors when the id is not one of your organization's
  instances.
  """
  tool :get_instance, read_only: true do
    field(:id, :string, required: true, description: "The instance's id")
  end

  @spec get_instance(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def get_instance(params, session) do
    with :ok <- require_scope(session, "instances:read"),
         {:ok, instance} <-
           Instance.get_by_id(params["id"], actor: session.assigns.user, authorize?: true) do
      detail = row(instance, "instance", @instance_detail_fields)
      {:reply, Phantom.Tool.structured(detail), session}
    else
      other -> tool_error(session, other)
    end
  end

  @description """
  The deployable app catalog. Call without arguments for every app
  (name, slug, tagline, description, icon/source/docs URLs, whether
  instances of it mount a file-access volume); pass `slug` to fetch a
  single app by its URL slug.
  """
  tool :list_apps, read_only: true do
    field(:slug, :string,
      description: "Fetch a single catalog app by its slug instead of listing all"
    )
  end

  @spec list_apps(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def list_apps(params, session) do
    with :ok <- require_scope(session, "catalog:read"),
         {:ok, apps} <- fetch_apps(params, session) do
      rows = %{apps: Enum.map(apps, &row(&1, "app", @app_fields))}
      {:reply, Phantom.Tool.structured(rows), session}
    else
      other -> tool_error(session, other)
    end
  end

  # The slug arm fetches ONE app — normalized to the list shape the
  # response row-builder consumes.
  defp fetch_apps(%{"slug" => slug}, session) when is_binary(slug) do
    with {:ok, app} <- App.get_by_slug(slug, actor: session.assigns.user, authorize?: true) do
      {:ok, [app]}
    end
  end

  defp fetch_apps(_params, session) do
    App.list(actor: session.assigns.user, authorize?: true)
  end

  @description """
  An instance's backup destination settings: S3 endpoint, bucket,
  prefix, access key id (an identifier — the secret never rides this
  surface), retention, enabled flag. Errors when the instance has no
  settings row (backups not configured) or is not yours.
  """
  tool :get_backup_settings, read_only: true do
    field(:instance_id, :string, required: true, description: "The instance's id")
  end

  @spec get_backup_settings(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def get_backup_settings(params, session) do
    with :ok <- require_scope(session, "backups:read"),
         {:ok, setting} <-
           BackupSetting.get_by_instance(params["instance_id"],
             actor: session.assigns.user,
             authorize?: true
           ) do
      detail = row(setting, "backup_setting", @backup_setting_fields)
      {:reply, Phantom.Tool.structured(detail), session}
    else
      other -> tool_error(session, other)
    end
  end

  @description """
  An instance's backup/restore history, newest first: kind (backup or
  restore), status, restic snapshot id, byte counts, error summary,
  timestamps. `limit` caps the page (1-100, default 20).
  """
  tool :list_backup_runs, read_only: true do
    field(:instance_id, :string, required: true, description: "The instance's id")

    field(:limit, :integer,
      default: 20,
      minimum: 1,
      maximum: 100,
      description: "How many runs to return (default 20)"
    )
  end

  @spec list_backup_runs(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def list_backup_runs(params, session) do
    with :ok <- require_scope(session, "backups:read"),
         {:ok, runs} <-
           BackupRun.recent_for_instance(params["instance_id"], params["limit"],
             actor: session.assigns.user,
             authorize?: true
           ) do
      rows = %{backup_runs: Enum.map(runs, &row(&1, "backup_run", @backup_run_fields))}
      {:reply, Phantom.Tool.structured(rows), session}
    else
      other -> tool_error(session, other)
    end
  end

  @description """
  Your organization's private-access gateway: opaque hostname, tailnet
  domain, provider, machine state (provisioning/active/
  needs_attention/suspended/destroying), status message, monthly rate,
  provisioned-at. Errors when the organization has no gateway or you
  are not a member.
  """
  tool :get_gateway, read_only: true do
    field(:organization_id, :string, required: true, description: "The organization's id")
  end

  @spec get_gateway(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def get_gateway(params, session) do
    with :ok <- require_scope(session, "gateways:read"),
         {:ok, gateway} <-
           AccessGateway.get_for_organization(params["organization_id"],
             actor: session.assigns.user,
             authorize?: true
           ) do
      detail = row(gateway, "access_gateway", @gateway_fields)
      {:reply, Phantom.Tool.structured(detail), session}
    else
      other -> tool_error(session, other)
    end
  end

  @description """
  Your organization's wallet, balance and projection in one response:
  `balance` (live ledger sum, whole cents), `paywall_waived`,
  `balance_cents` (the runway figure's unit), `burn_micro_cents_per_hour`
  (the current accrual rate) and `runway_hours` (hours until the
  balance hits zero at that rate — the string "infinity" when nothing
  accrues).
  """
  tool :get_wallet, read_only: true do
    field(:organization_id, :string, required: true, description: "The organization's id")
  end

  @spec get_wallet(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def get_wallet(params, session) do
    user = session.assigns.user

    with :ok <- require_scope(session, "wallet:read"),
         {:ok, wallet} <-
           Wallet.get_by_organization(params["organization_id"], actor: user, authorize?: true),
         {:ok, runway} <- wallet_runway(wallet, user) do
      # The balance aggregate load rides the same read policy the
      # authorized get just passed — a failure would be data corruption
      # (phantom renders the crash as a protocol-internal error).
      wallet = Ash.load!(wallet, :balance, actor: user, authorize?: true)

      attrs = %{
        organization_id: wallet.organization_id,
        balance: wallet.balance,
        paywall_waived: wallet.paywall_waived,
        balance_cents: runway.balance_cents,
        burn_micro_cents_per_hour: runway.burn_micro_cents_per_hour,
        runway_hours: runway.runway_hours
      }

      response = row(wallet, "wallet", attrs)
      {:reply, Phantom.Tool.structured(response), session}
    else
      other -> tool_error(session, other)
    end
  end

  defp wallet_runway(wallet, user) do
    args = %{organization_id: wallet.organization_id}

    input =
      Ash.ActionInput.for_action(Wallet, :runway, args, actor: user, authorize?: true)

    Ash.run_action(input)
  end

  @description """
  Your organization's ledger history, newest first — one entry per
  credit/debit: signed amount in whole cents, type, reason
  (purchase/adjustment/usage/...), idempotency key, tax facts
  (billing_country, billing_state, applied_rate, tax_cents,
  reverse_charge), subject. Keyset-paginated: pass `cursor` (the
  previous response's `next_cursor`) to page; `next_cursor` disappears
  from the response once you reached the end.
  """
  tool :list_ledger_entries, read_only: true do
    field(:wallet_id, :string, required: true, description: "The wallet's id")

    field(:cursor, :string, description: "Keyset cursor from the previous response's next_cursor")

    field(:limit, :integer,
      default: 25,
      minimum: 1,
      maximum: 100,
      description: "How many entries to return (default 25)"
    )
  end

  @spec list_ledger_entries(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def list_ledger_entries(params, session) do
    with :ok <- require_scope(session, "wallet:read"),
         {:ok, page} <- ledger_page(params, session.assigns.user) do
      response = ledger_rows(page)
      {:reply, Phantom.Tool.structured(response), session}
    else
      other -> tool_error(session, other)
    end
  end

  # The caller owns the sort like over HTTP's `sort=-id` — the tool
  # pins it server-side: uuidv7 id desc is the newest-first key, and a
  # stable sort is what the keyset cursor requires.
  defp ledger_page(params, user) do
    LedgerEntry
    |> Ash.Query.for_read(:list_for_wallet, %{wallet_id: params["wallet_id"]},
      actor: user,
      authorize?: true
    )
    |> Ash.Query.sort(id: :desc)
    |> Ash.read(page: keyset_page(params))
  end

  defp keyset_page(params) do
    limit = Map.get(params, "limit", 25)

    case Map.get(params, "cursor") do
      nil -> [limit: limit]
      cursor -> [limit: limit, after: cursor]
    end
  end

  defp ledger_rows(%Ash.Page.Keyset{} = page) do
    rows = %{entries: Enum.map(page.results, &row(&1, "ledger_entry", @ledger_fields))}

    case next_cursor(page) do
      nil -> rows
      cursor -> Map.put(rows, :next_cursor, cursor)
    end
  end

  # The cursor ash_json_api itself links with (serializer.ex): the last
  # result's keyset metadata — absent when the page exhausted the set.
  defp next_cursor(%Ash.Page.Keyset{more?: true, results: results}) when results != [] do
    results
    |> List.last()
    |> Map.get(:__metadata__)
    |> Map.get(:keyset)
  end

  defp next_cursor(_page), do: nil

  # --- the write tools -----------------------------------------------

  # The generic actions (delete / run_backup / restore_backup, the
  # gateway attach/detach pair) take id ARGUMENTS, not a changeset —
  # they ride an ActionInput like the wallet runway read above, and
  # the run's ownership fences re-read through their authorized
  # get_by_id (the resource policies' own posture).
  defp instance_action(action, args, user) do
    Instance
    |> Ash.ActionInput.for_action(action, args, actor: user, authorize?: true)
    |> Ash.run_action()
  end

  defp gateway_action(action, args, user) do
    AccessGateway
    |> Ash.ActionInput.for_action(action, args, actor: user, authorize?: true)
    |> Ash.run_action()
  end

  @description """
  Enqueue an instance's deployment — from :pending, or a retry from
  :error/:lost. Lands :deploying immediately (the namespace is pinned),
  then :starting; the platform's reconciler confirms readiness. Needs
  a positive wallet balance; the instance bills hourly once running.
  Refuses in any other state.
  """
  tool :deploy_instance, [] do
    field(:id, :string, required: true, description: "The instance's id")
  end

  @spec deploy_instance(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def deploy_instance(params, session) do
    with :ok <- require_scope(session, "instances:write"),
         {:ok, instance} <-
           Instance.get_by_id(params["id"], actor: session.assigns.user, authorize?: true),
         {:ok, deployed} <-
           Instance.deploy(instance, actor: session.assigns.user, authorize?: true) do
      detail = row(deployed, "instance", @instance_detail_fields)
      {:reply, Phantom.Tool.structured(detail), session}
    else
      other -> tool_error(session, other)
    end
  end

  @description """
  Scale an instance's app to zero — the pause. The running rate stops
  accruing; storage keeps accruing (the volume persists). Refuses
  unless the instance is running. Reverse with `start_instance`.
  """
  tool :stop_instance, [] do
    field(:id, :string, required: true, description: "The instance's id")
  end

  @spec stop_instance(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def stop_instance(params, session) do
    with :ok <- require_scope(session, "instances:write"),
         {:ok, instance} <-
           Instance.get_by_id(params["id"], actor: session.assigns.user, authorize?: true),
         {:ok, stopped} <- Instance.stop(instance, actor: session.assigns.user, authorize?: true) do
      detail = row(stopped, "instance", @instance_detail_fields)
      {:reply, Phantom.Tool.structured(detail), session}
    else
      other -> tool_error(session, other)
    end
  end

  @description """
  Scale a stopped or sleeping instance back up — lands :starting; the
  reconciler confirms readiness. Needs a positive wallet balance; the
  app bills hourly once running.
  """
  tool :start_instance, [] do
    field(:id, :string, required: true, description: "The instance's id")
  end

  @spec start_instance(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def start_instance(params, session) do
    with :ok <- require_scope(session, "instances:write"),
         {:ok, instance} <-
           Instance.get_by_id(params["id"], actor: session.assigns.user, authorize?: true),
         {:ok, started} <- Instance.start(instance, actor: session.assigns.user, authorize?: true) do
      detail = row(started, "instance", @instance_detail_fields)
      {:reply, Phantom.Tool.structured(detail), session}
    else
      other -> tool_error(session, other)
    end
  end

  @description """
  Toggle an instance's opt-out of scale-to-zero: `true` and the idle
  sweep never sleeps it — it bills the running rate around the clock.
  """
  tool :set_instance_always_on, [] do
    field(:id, :string, required: true, description: "The instance's id")

    field(:always_on, :boolean,
      required: true,
      description: "true keeps the instance from ever sleeping; false re-allows scale-to-zero"
    )
  end

  @spec set_instance_always_on(map(), Phantom.Session.t()) ::
          {:reply, map(), Phantom.Session.t()}
  def set_instance_always_on(params, session) do
    with :ok <- require_scope(session, "instances:write"),
         {:ok, instance} <-
           Instance.get_by_id(params["id"], actor: session.assigns.user, authorize?: true),
         {:ok, updated} <-
           Instance.set_always_on(instance, %{always_on: params["always_on"]},
             actor: session.assigns.user,
             authorize?: true
           ) do
      detail = row(updated, "instance", @instance_detail_fields)
      {:reply, Phantom.Tool.structured(detail), session}
    else
      other -> tool_error(session, other)
    end
  end

  @description """
  Toggle an instance's reachability: `public` serves its hostname at
  the edge; `private` removes the public route and denies edge ingress
  — pair it with `create_gateway` + `attach_instance` to reach it on
  your tailnet. Exposure itself bills nothing. Applied synchronously.
  """
  tool :set_instance_exposure, [] do
    field(:id, :string, required: true, description: "The instance's id")

    field(:exposure, :string,
      required: true,
      in: @exposures,
      description: "public or private"
    )
  end

  @spec set_instance_exposure(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def set_instance_exposure(params, session) do
    with :ok <- require_scope(session, "instances:write"),
         {:ok, instance} <-
           Instance.get_by_id(params["id"], actor: session.assigns.user, authorize?: true),
         {:ok, updated} <-
           Instance.set_exposure(instance, %{exposure: params["exposure"]},
             actor: session.assigns.user,
             authorize?: true
           ) do
      detail = row(updated, "instance", @instance_detail_fields)
      {:reply, Phantom.Tool.structured(detail), session}
    else
      other -> tool_error(session, other)
    end
  end

  @description """
  DESTROY an instance — deletes the volume data and tears down all its
  Kubernetes resources; the row goes with them. Asks first: the first
  call returns an input_required result carrying a confirm question;
  the teardown only starts after a "yes".
  """
  tool :destroy_instance, destructive: true do
    field(:id, :string, required: true, description: "The instance's id")
  end

  # The resume clause reads the WHAT from session.state (encrypted in
  # the requestState blob, bound to this user), never from the
  # re-sent params — a follow-up cannot steer the confirmed action at
  # a different id than the one the question named (phantom's
  # delete_file example's shape).
  # The ask arm returns {:noreply, ...} (the elicit ends the call);
  # the resume arms reply.
  @spec destroy_instance(map(), Phantom.Session.t()) ::
          {:reply, map(), Phantom.Session.t()} | {:noreply, Phantom.Session.t()}
  def destroy_instance(
        %{"confirm" => "yes"},
        %Phantom.Session{state: %{step: :confirming_destroy, instance_id: id}} = session
      ) do
    user = session.assigns.user

    with :ok <- require_scope(session, "instances:write"),
         {:ok, _gone} <- instance_action(:delete, %{id: id}, user) do
      {:reply,
       Phantom.Tool.text(
         "destroyed — the row is gone and its volume data and Kubernetes resources are being torn down"
       ), session}
    else
      other -> tool_error(session, other)
    end
  end

  # Any other resume answer — the form's "no", a decline, a cancel —
  # ends the call with nothing touched.
  def destroy_instance(_params, %Phantom.Session{state: %{step: :confirming_destroy}} = session) do
    {:reply, Phantom.Tool.text("cancelled — nothing was changed"), session}
  end

  # First call: resolve the instance (the not-found posture surfaces
  # BEFORE the question), then ask.
  def destroy_instance(params, session) do
    with :ok <- require_scope(session, "instances:write"),
         {:ok, instance} <-
           Instance.get_by_id(params["id"], actor: session.assigns.user, authorize?: true) do
      ask_confirm(session, :confirming_destroy, %{instance_id: instance.id},
        message:
          "destroy instance #{instance.name} (#{instance.slug}) — all data is deleted; confirm?"
      )
    else
      other -> tool_error(session, other)
    end
  end

  @description """
  Save an instance's backup destination: S3 endpoint, bucket, prefix,
  access key id (an identifier — the secret never rides this surface),
  retention, enabled. Writes the settings row — creating it or updating
  the existing one, whichever applies; you never need to care which.
  The repo credentials (the S3 secret key and restic password) live
  only in the instance's namespace Secret — the panel's save
  provisions them — and backups cannot run until they exist.
  """
  tool :configure_backups, [] do
    field(:instance_id, :string, required: true, description: "The instance's id")
    field(:endpoint, :string, required: true, description: "http(s):// host[:port], no path")
    field(:bucket, :string, required: true, description: "S3 bucket name")

    field(:prefix, :string,
      description: "optional key prefix inside the bucket (no leading/trailing slash)"
    )

    field(:access_key_id, :string, required: true, description: "The S3 access key's id")

    field(:retention_keep, :integer,
      minimum: 2,
      maximum: 30,
      description: "how many snapshots to keep (default 7)"
    )

    field(:enabled, :boolean, description: "false pauses backups (default true)")
  end

  @spec configure_backups(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def configure_backups(params, session) do
    user = session.assigns.user

    with :ok <- require_scope(session, "backups:write"),
         {:ok, instance} <-
           Instance.get_by_id(params["instance_id"], actor: user, authorize?: true) do
      save_backup_setting(instance, Map.take(params, @backup_param_fields), user, session)
    else
      other -> tool_error(session, other)
    end
  end

  # Get-by-instance first, then create or update — the agent never
  # cares which (the HTTP route's own create/update pair, one call).
  defp save_backup_setting(instance, params, user, session) do
    case BackupSetting.get_by_instance(instance.id, actor: user, authorize?: true) do
      {:ok, setting} ->
        update_backup_setting(setting, params, user, session)

      # No row (or unreadable) — the create arm. An existing row that
      # merely failed its read fails the unique constraint here, which
      # surfaces as a tool error: nothing is silently overwritten.
      _no_row ->
        create_backup_setting(instance, params, user, session)
    end
  end

  defp update_backup_setting(setting, params, user, session) do
    case BackupSetting.update(setting, params, actor: user, authorize?: true) do
      {:ok, updated} ->
        detail = row(updated, "backup_setting", @backup_setting_fields)
        {:reply, Phantom.Tool.structured(detail), session}

      {:error, _reason} = failure ->
        tool_error(session, failure)
    end
  end

  defp create_backup_setting(instance, params, user, session) do
    attrs = Map.put(params, "instance_id", instance.id)

    case BackupSetting.create(attrs, actor: user, authorize?: true) do
      {:ok, created} ->
        detail = row(created, "backup_setting", @backup_setting_fields)
        {:reply, Phantom.Tool.structured(detail), session}

      {:error, _reason} = failure ->
        tool_error(session, failure)
    end
  end

  @description """
  Run a backup now — one snapshot to the instance's configured
  destination. Needs backups configured and enabled, the app deployed,
  no run already in flight, and a positive wallet balance. Returns the
  run row (it starts :running; `list_backup_runs` tracks the finish).
  """
  tool :run_backup, [] do
    field(:id, :string, required: true, description: "The instance's id")
  end

  @spec run_backup(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def run_backup(params, session) do
    with :ok <- require_scope(session, "backups:write"),
         {:ok, run} <-
           instance_action(:run_backup, %{id: params["id"]}, session.assigns.user) do
      detail = row(run, "backup_run", @backup_run_fields)
      {:reply, Phantom.Tool.structured(detail), session}
    else
      other -> tool_error(session, other)
    end
  end

  @description """
  RESTORE an instance's volume from a snapshot — OVERWRITES the
  current volume state with the backup's. The run id must be the
  newest successful backup. Asks first: the first call returns an
  input_required result carrying a confirm question; the restore only
  starts after a "yes".
  """
  tool :restore_backup, destructive: true do
    field(:id, :string, required: true, description: "The instance's id")

    field(:backup_run_id, :string,
      required: true,
      # The action argument is a uuid — a garbage id could never run,
      # so the schema refuses it BEFORE the question (a confirm round
      # trip for an unrestorable id is wasted work for the user).
      pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
      description: "The backup run to restore from (must be the newest successful one)"
    )
  end

  # Resume arms mirror destroy_instance's (the state, not the re-sent
  # params, names the confirmed target).
  @spec restore_backup(map(), Phantom.Session.t()) ::
          {:reply, map(), Phantom.Session.t()} | {:noreply, Phantom.Session.t()}
  def restore_backup(
        %{"confirm" => "yes"},
        %Phantom.Session{
          state: %{step: :confirming_restore, instance_id: id, backup_run_id: run_id}
        } = session
      ) do
    user = session.assigns.user

    with :ok <- require_scope(session, "backups:write"),
         {:ok, run} <- instance_action(:restore_backup, %{id: id, backup_run_id: run_id}, user) do
      detail = row(run, "backup_run", @backup_run_fields)
      {:reply, Phantom.Tool.structured(detail), session}
    else
      other -> tool_error(session, other)
    end
  end

  def restore_backup(_params, %Phantom.Session{state: %{step: :confirming_restore}} = session) do
    {:reply, Phantom.Tool.text("cancelled — nothing was changed"), session}
  end

  def restore_backup(params, session) do
    with :ok <- require_scope(session, "backups:write"),
         {:ok, instance} <-
           Instance.get_by_id(params["id"], actor: session.assigns.user, authorize?: true) do
      ask_confirm(
        session,
        :confirming_restore,
        %{instance_id: instance.id, backup_run_id: params["backup_run_id"]},
        message:
          "restore snapshot #{params["backup_run_id"]} onto instance #{instance.name} " <>
            "(#{instance.slug}) — the current volume state is OVERWRITTEN; confirm?"
      )
    else
      other -> tool_error(session, other)
    end
  end

  # The one elicit shape: end the call with the confirm question, the
  # action's inputs riding the encrypted requestState (no server
  # state). The client's answer re-enters the handler.
  defp ask_confirm(session, step, state, message: message) do
    elicit =
      Phantom.Elicit.form(%{message: message, requested_schema: @confirm_schema})

    {:noreply, Phantom.Session.elicit(session, elicit, state: Map.put(state, :step, step))}
  end

  @description """
  Attach a private instance to the org's gateway — it becomes
  reachable on your tailnet. The instance must be private and
  deployed; the gateway must be active. One pairing per instance.
  """
  tool :attach_instance, [] do
    field(:gateway_id, :string, required: true, description: "The gateway's id")
    field(:instance_id, :string, required: true, description: "The instance's id")
  end

  @spec attach_instance(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def attach_instance(params, session) do
    args = %{gateway_id: params["gateway_id"], instance_id: params["instance_id"]}

    with :ok <- require_scope(session, "gateways:write"),
         {:ok, route} <- gateway_action(:attach_instance, args, session.assigns.user) do
      attrs = Map.take(route, [:gateway_id, :instance_id, :route_key])
      detail = row(route, "access_route", attrs)
      {:reply, Phantom.Tool.structured(detail), session}
    else
      other -> tool_error(session, other)
    end
  end

  @description """
  Detach an instance from the gateway — idempotent: detaching a
  non-attached pair succeeds. The instance keeps running; it just
  loses the tailnet route.
  """
  tool :detach_instance, idempotent: true do
    field(:gateway_id, :string, required: true, description: "The gateway's id")
    field(:instance_id, :string, required: true, description: "The instance's id")
  end

  @spec detach_instance(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def detach_instance(params, session) do
    args = %{gateway_id: params["gateway_id"], instance_id: params["instance_id"]}

    with :ok <- require_scope(session, "gateways:write"),
         :ok <- gateway_action(:detach_instance, args, session.assigns.user) do
      {:reply, Phantom.Tool.text("detached"), session}
    else
      other -> tool_error(session, other)
    end
  end

  @description """
  Create your organization's private-access gateway — one per org.
  Needs a Tailscale auth key and the tailnet's MagicDNS domain.
  Bills #{@gateway_rate} while active; needs a funded wallet that has
  completed at least one payment. Reversible: removing it tears the
  pod down (billing stops with it).
  """
  tool :create_gateway, [] do
    field(:tailnet_domain, :string, required: true, description: "Your tailnet's MagicDNS domain")
    field(:auth_key, :string, required: true, description: "A Tailscale auth key")
  end

  @spec create_gateway(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def create_gateway(params, session) do
    input = %{tailnet_domain: params["tailnet_domain"], auth_key: params["auth_key"]}

    with :ok <- require_scope(session, "gateways:write"),
         {:ok, gateway} <-
           AccessGateway.create(input, actor: session.assigns.user, authorize?: true) do
      detail = row(gateway, "access_gateway", @gateway_fields)
      {:reply, Phantom.Tool.structured(detail), session}
    else
      other -> tool_error(session, other)
    end
  end

  @description """
  Resume a suspended gateway — scale the pod back up and reopen the
  billing anchor (#{@gateway_rate} while active). Needs a funded wallet
  that has completed at least one payment; the observer confirms
  readiness.
  """
  tool :resume_gateway, [] do
    field(:id, :string, required: true, description: "The gateway's id")
  end

  @spec resume_gateway(map(), Phantom.Session.t()) :: {:reply, map(), Phantom.Session.t()}
  def resume_gateway(params, session) do
    user = session.assigns.user

    with :ok <- require_scope(session, "gateways:write"),
         {:ok, gateway} <- AccessGateway.get_by_id(params["id"], actor: user, authorize?: true),
         {:ok, resumed} <- AccessGateway.resume(gateway, actor: user, authorize?: true) do
      detail = row(resumed, "access_gateway", @gateway_fields)
      {:reply, Phantom.Tool.structured(detail), session}
    else
      other -> tool_error(session, other)
    end
  end

  # --- the helpers ---------------------------------------------------

  # The scope arm of the defense-in-depth dispatch check. Sessions are
  # only ever granted by connect/2 from a live PAT, so `:any` passes;
  # everything else asks the same catalog the /api/v1 boundary asks.
  defp require_scope(_session, :any), do: :ok

  defp require_scope(session, required) do
    if scope_granted?(session.assigns.pat, required) do
      :ok
    else
      {:refused, "this token lacks the #{required} scope"}
    end
  end

  # The `with` else arm: scope refusals and Ash failures (policy
  # denials, not-found) surface as TOOL errors carrying the reason —
  # never protocol errors, never stacktraces.
  defp tool_error(session, {:refused, message}) do
    {:reply, Phantom.Tool.error(message), session}
  end

  defp tool_error(session, {:error, reason}) do
    message = failure_message(reason)
    {:reply, Phantom.Tool.error(message), session}
  end

  # Every error the actions surface arrives as an Ash error CLASS —
  # even a generic action's own leaf comes back wrapped (a refusal
  # probes as %Ash.Error.Invalid{} around its InvalidArgument). The
  # classes render as multi-line reports with stacktrace frames; the
  # LEAF children are what surface — the writers' words, the policy
  # pair, or NotFound's own render (deduped — a policy's checks often
  # refuse twice).
  defp failure_message(reason) do
    reason.errors
    |> Enum.map(&leaf_message/1)
    |> Enum.uniq()
    |> Enum.join("; ")
  end

  # The leaves render through their own words: most carry a message
  # field (the writers'); policy leaves answer "forbidden" or their
  # custom message; NotFound — which has NO message field — renders
  # through Exception.message ("record not found"), the not-found
  # posture every foreign-id call sees.
  defp leaf_message(%{message: message}) when is_binary(message), do: message

  # The operations' custom-message policies (restore's ownership fence
  # words) could only arrive PAST the action's own identical
  # get_by_id — an interleaving tests cannot stage; the clause keeps
  # those words honest if a caller ever reaches it.
  defp leaf_message(%Ash.Error.Forbidden.Policy{custom_message: message})
       when is_binary(message) do
    # coveralls-ignore-next-line - the action's get_by_id (same read) answers first; nothing reaches this clause.
    message
  end

  defp leaf_message(%Ash.Error.Forbidden.Policy{}), do: "forbidden"

  # NotFound's arm — the not-found posture of every foreign-id call.
  defp leaf_message(other), do: Exception.message(other)

  defp row(resource, type, fields) when is_list(fields) do
    attributes = Map.new(fields, fn field -> {field, Map.get(resource, field)} end)
    row(resource, type, attributes)
  end

  defp row(resource, type, attributes) when is_map(attributes) do
    %{
      id: Map.get(resource, :id),
      type: type,
      attributes: jsonify(attributes)
    }
  end

  # Everything crossing the wire must survive stdlib `JSON.encode!`
  # (phantom's transport): atoms become their name strings (status
  # atoms, the `:infinity` runway — the same shape the HTTP runway
  # route ships), decimals their literal string (no float rounding),
  # timestamps ISO-8601. The struct clauses precede the map clause —
  # a struct IS a map, and the generic recursion would shred a
  # Decimal into its internal fields.
  defp jsonify(%Decimal{} = decimal), do: Decimal.to_string(decimal)
  defp jsonify(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp jsonify(value) when is_map(value) do
    Map.new(value, fn {key, inner} -> {key, jsonify(inner)} end)
  end

  defp jsonify(list) when is_list(list), do: Enum.map(list, &jsonify/1)

  defp jsonify(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom),
    do: Atom.to_string(atom)

  defp jsonify(other), do: other
end
