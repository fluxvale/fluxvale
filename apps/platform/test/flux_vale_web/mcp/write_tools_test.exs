defmodule FluxValeWeb.Mcp.WriteToolsTest do
  @moduledoc """
  The ten non-confirming write tools' wire contract (#361 slice 2):
  the same actions the HTTP write routes ride, with the resource
  guards' own words surfacing as tool errors.

  The dispatches run through `Phantom.Test.call_tool` — IN this
  process — because the handlers' actions reach the Mimic-stubbed
  cluster surface, and stubs stay per-process (the transport spawns
  its handler workers, where they would not apply; the confirmation
  suite covers the wire-level shape, and the read tools' transport
  contract is tools_test's).
  """

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.BackupJob
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxValeWeb.MCP.Router

  setup do
    # The dispatcher resolves tools through phantom's :persistent_term
    # cache — register the router like the plug does.
    Phantom.Test.start(router: Router)
    :ok
  end

  # --- the instances family ------------------------------------------

  describe "deploy_instance" do
    setup :stub_deploy_cluster

    test "enqueues the deploy — the write's own answer is :deploying with the namespace", %{
      conn: _conn
    } do
      {user, pat_row, instance} = paid_member_with_pending_instance()

      result = call(user, pat_row, :deploy_instance, %{"id" => instance.id})

      attributes = attributes!(result)

      assert attributes[:status] == "deploying"
      assert attributes[:namespace] == "fluxvale-app-#{instance.id}"
    end

    test "a running instance is refused with the action's own guard words", %{
      conn: _conn
    } do
      {user, pat_row, instance} = paid_member_with_running_instance()

      result = call(user, pat_row, :deploy_instance, %{"id" => instance.id})

      assert tool_error_text(result) =~
               "cannot deploy instance in running state (must be pending, error, or lost)"
    end

    # The funded gate is policy-land (ActorOrgWalletFunded): its plain
    # words are Ash's "forbidden" — the same refusal the /api/v1 route
    # maps to a 403 (paywall_route_test's zero-balance proof).
    test "a zero-balance org's deploy is refused by the funded gate", %{conn: _conn} do
      {user, pat_row} = full_scopes_pat!()
      org = BillingFixtures.mark_user_paid!(user)
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()
      instance = InstanceFixtures.instance!(version, user)
      :ok = BillingFixtures.drain_wallet!(org)

      result = call(user, pat_row, :deploy_instance, %{"id" => instance.id})

      assert tool_error_text(result) == "forbidden"
    end
  end

  describe "stop_instance / start_instance" do
    setup do
      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(Deployment, :scale, fn _kc, _ns, _n, _replicas -> {:ok, %{}} end)
      :ok
    end

    test "stop scales a running instance to zero", %{conn: _conn} do
      {user, pat_row, instance} = paid_member_with_running_instance()

      result = call(user, pat_row, :stop_instance, %{"id" => instance.id})

      assert attributes!(result)[:status] == "stopped"
    end

    test "start scales a stopped instance back up", %{conn: _conn} do
      {user, pat_row, instance} = paid_member_with_stopped_instance()

      result = call(user, pat_row, :start_instance, %{"id" => instance.id})

      assert attributes!(result)[:status] == "starting"
    end

    test "starting a running instance is refused with the action's own guard words", %{
      conn: _conn
    } do
      {user, pat_row, instance} = paid_member_with_running_instance()

      result = call(user, pat_row, :start_instance, %{"id" => instance.id})

      assert tool_error_text(result) =~
               "cannot start instance in running state (must be stopped or sleeping)"
    end

    test "a pending instance is refused with the action's own guard words", %{conn: _conn} do
      {user, pat_row, instance} = paid_member_with_pending_instance()

      result = call(user, pat_row, :stop_instance, %{"id" => instance.id})

      assert tool_error_text(result) =~ "cannot stop instance in pending state (must be running)"
    end
  end

  describe "set_instance_always_on / set_instance_exposure" do
    test "flips the always-on opt-out", %{conn: _conn} do
      {user, pat_row, instance} = paid_member_with_pending_instance()

      result =
        call(user, pat_row, :set_instance_always_on, %{"id" => instance.id, "always_on" => true})

      assert attributes!(result)[:always_on] == true
    end

    test "toggles exposure on a never-deployed row (attribute-only)", %{conn: _conn} do
      {user, pat_row, instance} = paid_member_with_pending_instance()

      result =
        call(user, pat_row, :set_instance_exposure, %{
          "id" => instance.id,
          "exposure" => "private"
        })

      assert attributes!(result)[:exposure] == "private"
    end

    test "an exposure outside the resource's enum is refused before the action", %{conn: _conn} do
      {user, pat_row, instance} = paid_member_with_pending_instance()

      # The input schema's enum — laundered through Enum.at to keep the
      # deliberate type violation out of --warnings-as-errors.
      result =
        call(user, pat_row, :set_instance_exposure, %{
          "id" => instance.id,
          "exposure" => Enum.at(["banana"], 0)
        })

      assert tool_error_text(result) =~ "Invalid tool arguments"
    end

    test "a foreign instance id gets the action's not-found posture", %{conn: _conn} do
      {user, pat_row} = full_scopes_pat!()
      BillingFixtures.mark_user_paid!(user)
      foreign = pending_instance_for_other_member!()

      always_on_result =
        call(user, pat_row, :set_instance_always_on, %{
          "id" => foreign.id,
          "always_on" => true
        })

      assert tool_error_text(always_on_result) =~ "not found"

      exposure_result =
        call(user, pat_row, :set_instance_exposure, %{
          "id" => foreign.id,
          "exposure" => "private"
        })

      assert tool_error_text(exposure_result) =~ "not found"
    end
  end

  # --- the backups family --------------------------------------------

  describe "configure_backups" do
    test "creates the settings row for an unconfigured instance", %{conn: _conn} do
      {user, pat_row, instance} = paid_member_with_pending_instance()

      result = call(user, pat_row, :configure_backups, backup_params(instance))

      row = row!(result, "backup_setting")
      assert row[:attributes][:instance_id] == instance.id
      assert row[:attributes][:bucket] == "fluxvale-kavita"
      assert row[:attributes][:retention_keep] == 7
    end

    test "updates the existing row — same id, new retention", %{conn: _conn} do
      {user, pat_row, instance} = paid_member_with_pending_instance()
      setting = backup_setting!(instance)

      # The tool's contract is a FULL save (the schema requires the
      # coordinates) — the update arm differs only in which row lands.
      result =
        call(user, pat_row, :configure_backups, %{
          "instance_id" => instance.id,
          "endpoint" => "https://account.r2.cloudflarestorage.com",
          "bucket" => "fluxvale-kavita",
          "prefix" => "fluxvale/app",
          "access_key_id" => "AKIAIOSFODNN7EXAMPLE",
          "retention_keep" => 14
        })

      row = row!(result, "backup_setting")
      assert row[:id] == setting.id
      assert row[:attributes][:retention_keep] == 14
    end

    test "bad input is refused with the resource's own validation words", %{conn: _conn} do
      {user, pat_row, instance} = paid_member_with_pending_instance()
      base = backup_params(instance)
      params = Map.put(base, "endpoint", "ftp://not-s3.example.com")

      result = call(user, pat_row, :configure_backups, params)

      assert tool_error_text(result) =~
               "must be an http:// or https:// URL with a host and no path"
    end

    test "a save over an existing row refuses bad input the same way", %{conn: _conn} do
      {user, pat_row, instance} = paid_member_with_pending_instance()
      backup_setting!(instance)
      base = backup_params(instance)
      params = Map.put(base, "endpoint", "ftp://not-s3.example.com")

      result = call(user, pat_row, :configure_backups, params)

      assert tool_error_text(result) =~
               "must be an http:// or https:// URL with a host and no path"
    end

    test "a foreign instance id gets the action's not-found posture", %{conn: _conn} do
      {user, pat_row} = full_scopes_pat!()
      BillingFixtures.mark_user_paid!(user)
      foreign = pending_instance_for_other_member!()

      params = backup_params(foreign)

      result = call(user, pat_row, :configure_backups, params)

      assert %{:isError => true} = result
    end

    # The paid-once gate is policy-land on the RESOURCE's create (the
    # same authority the HTTP route's POST rides): "forbidden" — a
    # JIT member's org is welcome-funded but has never paid.
    test "a never-paid org's save is refused by the paid-once gate", %{conn: _conn} do
      {user, pat_row, instance} = never_paid_member_with_pending_instance()

      result = call(user, pat_row, :configure_backups, backup_params(instance))

      assert tool_error_text(result) == "forbidden"
    end
  end

  describe "run_backup" do
    setup :stub_backup_cluster

    test "runs a manual backup — the run row comes back", %{conn: _conn} do
      {user, pat_row, instance} = paid_member_with_running_instance()
      backup_setting!(instance)

      result = call(user, pat_row, :run_backup, %{"id" => instance.id})

      row = row!(result, "backup_run")
      assert row[:attributes][:kind] == "manual"
      assert row[:attributes][:status] == "running"
      assert row[:attributes][:instance_id] == instance.id
    end

    test "an unconfigured instance is refused with the operation's own words", %{conn: _conn} do
      {user, pat_row, instance} = paid_member_with_running_instance()

      result = call(user, pat_row, :run_backup, %{"id" => instance.id})

      assert tool_error_text(result) =~ "backups are not configured for this instance"
    end
  end

  # --- the gateways family -------------------------------------------

  describe "create_gateway" do
    setup :stub_gateway_cluster

    test "creates the org's gateway — the price is the config's, the org the actor's", %{
      conn: _conn
    } do
      {user, org, pat_row} = paid_member_org()

      result =
        call(user, pat_row, :create_gateway, %{
          "tailnet_domain" => "example.ts.net",
          "auth_key" => "tskey-test"
        })

      row = row!(result, "access_gateway")
      assert row[:attributes][:organization_id] == org.id
      assert row[:attributes][:state] == "provisioning"

      assert row[:attributes][:monthly_cents] ==
               Application.fetch_env!(:flux_vale, :access_gateway)[:monthly_cents]

      # The auth key never comes back (ADR-0039 §4: no read-back).
      refute Map.has_key?(row[:attributes], :auth_key)
    end

    # The paid-once gate is policy-land (ActorOrgHasPaid): "forbidden"
    # — a JIT member's org is welcome-funded but has never paid.
    test "a never-paid org is refused by the paid-once gate", %{conn: _conn} do
      {user, pat_row} = never_paid_member()

      result =
        call(user, pat_row, :create_gateway, %{
          "tailnet_domain" => "example.ts.net",
          "auth_key" => "tskey-test"
        })

      assert tool_error_text(result) == "forbidden"
    end
  end

  describe "resume_gateway" do
    setup :stub_gateway_cluster

    test "resumes a suspended gateway — lands :provisioning", %{conn: _conn} do
      {user, org, pat_row} = paid_member_org()
      gateway = AccessFixtures.gateway!(org, state: :suspended)

      result = call(user, pat_row, :resume_gateway, %{"id" => gateway.id})

      assert attributes!(result)[:state] == "provisioning"
    end

    test "a foreign gateway id gets the action's not-found posture", %{conn: _conn} do
      {user, _org, pat_row} = paid_member_org()

      result = call(user, pat_row, :resume_gateway, %{"id" => Ecto.UUID.generate()})

      assert tool_error_text(result) =~ "not found"
    end
  end

  describe "attach_instance / detach_instance" do
    setup :stub_gateway_cluster

    test "attaches a private instance — the pairing row comes back", %{conn: _conn} do
      {user, org, pat_row} = paid_member_org()
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, user)

      result =
        call(user, pat_row, :attach_instance, %{
          "gateway_id" => gateway.id,
          "instance_id" => instance.id
        })

      row = row!(result, "access_route")
      assert row[:attributes][:gateway_id] == gateway.id
      assert row[:attributes][:instance_id] == instance.id
      assert row[:attributes][:route_key] == "8443"
    end

    test "a public instance is refused with the operation's own words", %{conn: _conn} do
      {user, org, pat_row} = paid_member_org()
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.public_instance!(org, user)

      result =
        call(user, pat_row, :attach_instance, %{
          "gateway_id" => gateway.id,
          "instance_id" => instance.id
        })

      assert tool_error_text(result) =~ "the instance is not private"
    end

    test "a provider failure passes the raw error through — no guard copy", %{conn: _conn} do
      {user, org, pat_row} = paid_member_org()
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, user)

      stub(Tailscale, :attach_instance, fn _gateway, _instance ->
        {:error, %Error{reason: :timeout, message: "provider timed out"}}
      end)

      result =
        call(user, pat_row, :attach_instance, %{
          "gateway_id" => gateway.id,
          "instance_id" => instance.id
        })

      # Ash wraps a generic action's raw {:error, struct} as
      # "unknown error: …" — the provider's own words stay inside, no
      # guard copy around them (the 500 route's stance).
      assert tool_error_text(result) =~ "provider timed out"
    end

    test "detach removes the pairing — idempotent success", %{conn: _conn} do
      {user, org, pat_row} = paid_member_org()
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, user)

      {:ok, _route} =
        FluxVale.Infrastructure.attach_instance(gateway, instance, authorize?: false)

      result =
        call(user, pat_row, :detach_instance, %{
          "gateway_id" => gateway.id,
          "instance_id" => instance.id
        })

      assert tool_text(result) == "detached"
      assert {:error, _gone} = AccessRoute.get_by_instance(instance.id, authorize?: false)
    end

    test "a foreign gateway id gets the action's not-found posture", %{conn: _conn} do
      {user, org, pat_row} = paid_member_org()
      instance = AccessFixtures.private_instance!(org, user)

      result =
        call(user, pat_row, :detach_instance, %{
          "gateway_id" => Ecto.UUID.generate(),
          "instance_id" => instance.id
        })

      assert tool_error_text(result) =~ "not found"
    end

    test "detaching a non-attached pair succeeds (idempotent)", %{conn: _conn} do
      {user, org, pat_row} = paid_member_org()
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, user)

      result =
        call(user, pat_row, :detach_instance, %{
          "gateway_id" => gateway.id,
          "instance_id" => instance.id
        })

      assert tool_text(result) == "detached"
    end
  end

  # --- the dispatch harness ------------------------------------------

  # The handler-level call: build the session connect/2 would grant
  # (the PAT ROW is the scope source) and dispatch in-process.
  defp call(user, pat_row, name, args) do
    session =
      Phantom.Test.build_session(Router,
        assigns: %{user: user, pat: pat_row, request_state_principal: user.id},
        protocol_version: "2026-07-28"
      )

    Phantom.Test.call_tool(session, name, args)
  end

  defp attributes!(result) do
    case result do
      %{structuredContent: %{attributes: attributes}} -> attributes
      other -> flunk("expected a structured row, got: #{inspect(other)}")
    end
  end

  defp row!(result, type) do
    case result do
      %{structuredContent: %{type: ^type} = row} -> row
      other -> flunk("expected a #{type} row, got: #{inspect(other)}")
    end
  end

  defp tool_error_text(%{isError: true, content: [%{text: text}]}), do: text

  defp tool_error_text(other), do: flunk("expected a tool error, got: #{inspect(other)}")

  defp tool_text(%{content: [%{text: text}]}), do: text
  defp tool_text(other), do: flunk("expected a text result, got: #{inspect(other)}")

  # --- fixtures (the API route suites' patterns) ----------------------

  defp pat_row!(raw) do
    hash = PersonalAccessToken.token_hash(raw)
    {:ok, pat} = PersonalAccessToken.get_by_token_hash(hash, authorize?: false)
    pat
  end

  # `{user, pat_row}` with a full-catalog token — the S1 grant set
  # (write scopes imply their reads).
  defp full_scopes_pat! do
    families = [:instances, :backups, :gateways]

    scopes =
      Enum.flat_map(families, fn family -> ["#{family}:write", "#{family}:read"] end)

    {user, raw} = ApiPat.member!(scopes ++ ["wallet:read", "catalog:read"])
    {user, pat_row!(raw)}
  end

  defp never_paid_member, do: full_scopes_pat!()

  # A pending instance belonging to a DIFFERENT member — the foreign-id
  # refusals' precondition (the helper owns the suite's one cluster;
  # ResolveCluster pins it).
  defp pending_instance_for_other_member! do
    InstanceFixtures.local_cluster!()

    {foreign_user, _raw} = ApiPat.member!()
    BillingFixtures.mark_user_paid!(foreign_user)

    version = InstanceFixtures.app_version!()

    InstanceFixtures.instance!(version, foreign_user)
  end

  defp paid_member_org do
    {user, pat_row} = full_scopes_pat!()
    org = BillingFixtures.mark_user_paid!(user)
    {user, org, pat_row}
  end

  defp paid_member_with_pending_instance do
    {user, pat_row} = full_scopes_pat!()
    BillingFixtures.mark_user_paid!(user)

    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance = InstanceFixtures.instance!(version, user)

    {user, pat_row, instance}
  end

  # `{user, pat_row, instance}` with a welcome-funded, NEVER-paid org —
  # the paid-once gates' precondition.
  defp never_paid_member_with_pending_instance do
    {user, pat_row} = full_scopes_pat!()

    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance = InstanceFixtures.instance!(version, user)

    {user, pat_row, instance}
  end

  defp paid_member_with_running_instance do
    {user, pat_row, instance} = paid_member_with_pending_instance()

    deployed =
      instance
      |> InstanceFixtures.pin!(namespace: "fluxvale-app-#{instance.id}")
      |> InstanceFixtures.walk_to!(:running)

    {user, pat_row, deployed}
  end

  defp paid_member_with_stopped_instance do
    # walk_to! always walks the full chain from :pending — start there,
    # not from an already-running row.
    {user, pat_row, pending} = paid_member_with_pending_instance()

    stopped =
      pending
      |> InstanceFixtures.pin!(namespace: "fluxvale-app-#{pending.id}")
      |> InstanceFixtures.walk_to!(:stopped)

    {user, pat_row, stopped}
  end

  defp backup_params(instance) do
    %{
      "instance_id" => instance.id,
      "endpoint" => "https://account.r2.cloudflarestorage.com",
      "bucket" => "fluxvale-kavita",
      "prefix" => "fluxvale/app",
      "access_key_id" => "AKIAIOSFODNN7EXAMPLE",
      "retention_keep" => 7,
      "enabled" => true
    }
  end

  defp backup_setting!(instance) do
    BackupSetting
    |> Ash.Changeset.for_create(
      :create,
      %{
        instance_id: instance.id,
        endpoint: "https://account.r2.cloudflarestorage.com",
        bucket: "fluxvale-kavita",
        prefix: "fluxvale/app",
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        retention_keep: 7
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  # --- cluster stub sets (the API route suites' own shapes) -----------

  # The deploy trigger's inline run applies the whole namespace
  # (instance_route_test's stub_k8s).
  defp stub_deploy_cluster(_context) do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Secret, :create, fn _kc, _ns, _n, _data -> {:ok, %{}} end)
    stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _name, _spec -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)

    :ok
  end

  # The backup op's happy-path cluster (backup_route_test's own set).
  defp stub_backup_cluster(_context) do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
    stub(BackupJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    :ok
  end

  # The gateway family's provider + edge stub set (gateway_route_test's
  # own setup).
  defp stub_gateway_cluster(_context) do
    InstanceFixtures.local_cluster!()

    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
    stub(Tailscale, :teardown_gateway, fn _gateway -> :ok end)

    stub(Tailscale, :attach_instance, fn gateway, instance ->
      {:ok,
       AccessRoute.create!(
         %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
         authorize?: false
       )}
    end)

    stub(Tailscale, :detach_instance, fn gateway, instance ->
      # The provider's own order is policy → row → configs — the row
      # delete is the provider's limb, so the stub plays it.
      case AccessRoute.get_by_pair(gateway.id, instance.id, authorize?: false) do
        {:ok, route} ->
          Ash.destroy!(route, authorize?: false)
          :ok

        {:error, _gone} ->
          :ok
      end
    end)

    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :delete, fn _kc, _ns, _n -> {:error, %Error{reason: :not_found}} end)
    stub(Middleware, :delete, fn _kc, _ns, _n -> {:error, %Error{reason: :not_found}} end)

    stub(RenderAccessDNS, :call, fn -> :ok end)
    stub(RenderAccessDNS, :call, fn _opts -> :ok end)

    :ok
  end
end
