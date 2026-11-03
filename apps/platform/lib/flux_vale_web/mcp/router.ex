defmodule FluxValeWeb.MCP.Router do
  @moduledoc """
  FluxVale's MCP server: read tools over your FluxVale account,
  authenticated with your personal access token (PAT).

  What this server exposes:

  - **Instances** — the apps you deployed (`list_instances`,
    `get_instance`), with lifecycle status and allocation.
  - **Backups** — an instance's backup settings (`get_backup_settings`)
    and its run history (`list_backup_runs`).
  - **Access** — your organization's private-access gateway status
    (`get_gateway`).
  - **Billing** — wallet balance plus projected runway (`get_wallet`)
    and the ledger history (`list_ledger_entries`).
  - **Catalog** — the deployable app catalog (`list_apps`).
  - **`whoami`** — the identity your token carries and its scopes.

  Every tool in this slice READS. Writes (deploy, stop, backup now,
  restore) are explicit tools that arrive in a later slice, and the
  destructive ones will require your confirmation before acting. Tools
  are scope-filtered per token: `tools/list` only ever offers what the
  token's scopes cover (a read-only token never sees a write tool),
  and each handler re-checks the scope before acting.

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
  # already makes such a call unresolvable).
  @tool_scopes %{
    "whoami" => :any,
    "list_instances" => "instances:read",
    "get_instance" => "instances:read",
    "list_apps" => "catalog:read",
    "get_backup_settings" => "backups:read",
    "list_backup_runs" => "backups:read",
    "get_gateway" => "gateways:read",
    "get_wallet" => "wallet:read",
    "list_ledger_entries" => "wallet:read"
  }

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
    %{session | assigns: Map.merge(session.assigns, %{user: user, pat: pat})}
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
    message = Exception.message(reason)
    {:reply, Phantom.Tool.error(message), session}
  end

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
