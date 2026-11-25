defmodule FluxVale.Infrastructure.Operations.SyncInstanceUrlEnvTest do
  @moduledoc false

  # The address-event sync (ADR-0052's seam, third consumer): the
  # recompute from ONE derivation snapshot, the no-op contract (no
  # write, no roll when the live Secret already matches), the UpdateEnv
  # status dispatch, and the never-write-the-row rule.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.SyncInstanceUrlEnv
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    verify_on_exit!()

    stub(Kubereq, :attach, fn req, _opts -> req end)

    stub(Kubereq, :apply, fn _req, manifest, _fm ->
      {:ok, %{status: 201, body: manifest}}
    end)

    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    {org, owner} = BillingFixtures.grant_free_org!()
    {^org, _wallet} = BillingFixtures.funded_wallet!(org: org)
    InstanceFixtures.local_cluster!()

    {:ok, org: org, owner: owner}
  end

  describe "call/1 — the live statuses" do
    test "running with a live custom address upserts the URL key and rolls once", %{
      org: org,
      owner: owner
    } do
      {instance, _gateway, domain} =
        live_custom!(org, owner, instance_url_env: "ROOT_URL")

      stub(Secret, :get_data, fn _kc, _ns, "app-env" -> {:ok, %{}} end)

      expect(Secret, :upsert, fn _kc, ns, "app-env", data ->
        send(self(), {:upsert, ns, data})
        {:ok, %{}}
      end)

      expect(Deployment, :restart, fn _kc, _ns, "app", _opts ->
        send(self(), :restarted)
        {:ok, %{}}
      end)

      # the binary (id) input arm
      assert :ok = SyncInstanceUrlEnv.call(instance.id)

      ns = "fluxvale-app-#{instance.id}"
      url = "https://git.#{domain.domain}/"
      assert_received {:upsert, ^ns, %{"ROOT_URL" => ^url}}
      assert_received :restarted
    end

    test "a live Secret already carrying the address is a no-op — no write, no roll", %{
      org: org,
      owner: owner
    } do
      {instance, _gateway, domain} =
        live_custom!(org, owner, instance_url_env: "ROOT_URL", host_allowlist_env: "ALLOWED")

      url = "https://git.#{domain.domain}/"

      stub(Secret, :get_data, fn _kc, _ns, "app-env" ->
        {:ok, %{"ROOT_URL" => url, "ALLOWED" => "git.#{domain.domain}"}}
      end)

      # The no-op contract: no expectation set — either write fails the test.
      reject(Secret, :upsert, 4)
      reject(Deployment, :restart, 4)
      reject(Deployment, :ensure_env_from, 3)

      assert :ok = SyncInstanceUrlEnv.call(instance)
    end

    test "a claim removed between setup and call drops the URL key", %{org: org, owner: owner} do
      {instance, gateway, domain} = live_custom!(org, owner, instance_url_env: "ROOT_URL")
      AccessFixtures.claim!(gateway, [])

      stub(Secret, :get_data, fn _kc, _ns, "app-env" ->
        {:ok, %{"ROOT_URL" => "https://git.#{domain.domain}/"}}
      end)

      expect(Secret, :upsert, fn _kc, _ns, "app-env", data ->
        send(self(), {:upsert, data})
        {:ok, %{}}
      end)

      expect(Deployment, :restart, fn _kc, _ns, "app", _opts -> {:ok, %{}} end)

      assert :ok = SyncInstanceUrlEnv.call(instance)

      # the URL key went nil — it leaves the merged Secret entirely
      assert_received {:upsert, %{}}
    end

    test "a failed Secret read surfaces the error", %{org: org, owner: owner} do
      {instance, _gateway, _domain} = live_custom!(org, owner, instance_url_env: "ROOT_URL")

      stub(Secret, :get_data, fn _kc, _ns, _name ->
        {:error, %K8s.Error{status_code: 503, reason: :unavailable, message: "down"}}
      end)

      assert {:error, %K8s.Error{reason: :unavailable}} = SyncInstanceUrlEnv.call(instance)
    end

    test "the allowlist rides one snapshot: ONE upsert sets both keys, one roll", %{
      org: org,
      owner: owner
    } do
      {instance, _gateway, domain} =
        live_custom!(org, owner, instance_url_env: "ROOT_URL", host_allowlist_env: "ALLOWED")

      stub(Secret, :get_data, fn _kc, _ns, "app-env" -> {:ok, %{"ALLOWED" => "localhost"}} end)

      expected = %{
        "ROOT_URL" => "https://git.#{domain.domain}/",
        "ALLOWED" => "localhost,git.#{domain.domain}"
      }

      expect(Secret, :upsert, 1, fn _kc, _ns, "app-env", data ->
        send(self(), {:upsert, data})
        {:ok, %{}}
      end)

      expect(Deployment, :restart, 1, fn _kc, _ns, "app", _opts ->
        send(self(), :restarted)
        {:ok, %{}}
      end)

      assert :ok = SyncInstanceUrlEnv.call(instance)

      assert_received {:upsert, ^expected}
      assert_received :restarted
    end

    test "a nil URL is not a skip: the URL key removal still writes and rolls", %{
      org: org,
      owner: owner
    } do
      {instance, gateway, domain} =
        live_custom!(org, owner, instance_url_env: "ROOT_URL", host_allowlist_env: "ALLOWED")

      AccessFixtures.claim!(gateway, [])

      stub(Secret, :get_data, fn _kc, _ns, "app-env" ->
        {:ok,
         %{"ROOT_URL" => "https://git.#{domain.domain}/", "ALLOWED" => "git.#{domain.domain}"}}
      end)

      expected = %{"ALLOWED" => "git.#{domain.domain}"}

      expect(Secret, :upsert, fn _kc, _ns, "app-env", data ->
        send(self(), {:upsert, data})
        {:ok, %{}}
      end)

      expect(Deployment, :restart, fn _kc, _ns, "app", _opts ->
        send(self(), :restarted)
        {:ok, %{}}
      end)

      assert :ok = SyncInstanceUrlEnv.call(instance)

      # the URL key is gone, the allowlist rides unchanged — the write
      # still happened
      assert_received {:upsert, ^expected}
      assert_received :restarted
    end

    test "a version naming only the allowlist writes when the URL arm is inert", %{
      org: org,
      owner: owner
    } do
      {instance, _gateway, domain} = live_custom!(org, owner, host_allowlist_env: "ALLOWED")

      stub(Secret, :get_data, fn _kc, _ns, "app-env" -> {:ok, %{"ALLOWED" => "localhost"}} end)

      expected = %{"ALLOWED" => "localhost,git.#{domain.domain}"}

      expect(Secret, :upsert, fn _kc, _ns, "app-env", data ->
        send(self(), {:upsert, data})
        {:ok, %{}}
      end)

      expect(Deployment, :restart, fn _kc, _ns, "app", _opts ->
        send(self(), :restarted)
        {:ok, %{}}
      end)

      assert :ok = SyncInstanceUrlEnv.call(instance)

      assert_received {:upsert, ^expected}
      assert_received :restarted
    end

    test "an allowlist-only change writes and rolls for the allowlist alone", %{
      org: org,
      owner: owner
    } do
      {instance, _gateway, domain} =
        live_custom!(org, owner, instance_url_env: "ROOT_URL", host_allowlist_env: "ALLOWED")

      url = "https://git.#{domain.domain}/"

      stub(Secret, :get_data, fn _kc, _ns, "app-env" ->
        {:ok, %{"ROOT_URL" => url, "ALLOWED" => "localhost"}}
      end)

      expected = %{"ROOT_URL" => url, "ALLOWED" => "localhost,git.#{domain.domain}"}

      expect(Secret, :upsert, fn _kc, _ns, "app-env", data ->
        send(self(), {:upsert, data})
        {:ok, %{}}
      end)

      expect(Deployment, :restart, fn _kc, _ns, "app", _opts ->
        send(self(), :restarted)
        {:ok, %{}}
      end)

      assert :ok = SyncInstanceUrlEnv.call(instance)

      assert_received {:upsert, ^expected}
      assert_received :restarted
    end
  end

  describe "call/1 — the secret-only statuses" do
    test "stopped with a new Secret: upsert and the spec-only ensure, no restart", %{
      org: org,
      owner: owner
    } do
      {instance, _gateway, domain} =
        live_custom!(org, owner, [instance_url_env: "ROOT_URL"], :stopped)

      stub(Secret, :get_data, fn _kc, _ns, "app-env" ->
        {:error, %K8s.Error{status_code: 404, reason: :not_found, message: "absent"}}
      end)

      expect(Secret, :upsert, fn _kc, ns, "app-env", data ->
        send(self(), {:upsert, ns, data})
        {:ok, %{}}
      end)

      expect(Deployment, :ensure_env_from, fn _kc, _ns, "app" ->
        send(self(), :ensured)
        {:ok, %{}}
      end)

      reject(Deployment, :restart, 4)

      assert :ok = SyncInstanceUrlEnv.call(instance)

      ns = "fluxvale-app-#{instance.id}"
      url = "https://git.#{domain.domain}/"
      assert_received {:upsert, ^ns, %{"ROOT_URL" => ^url}}
      assert_received :ensured
    end

    test "stopped with an existing Secret: upsert only — no ensure, no restart", %{
      org: org,
      owner: owner
    } do
      {instance, _gateway, domain} =
        live_custom!(org, owner, [instance_url_env: "ROOT_URL"], :stopped)

      stub(Secret, :get_data, fn _kc, _ns, "app-env" -> {:ok, %{}} end)

      expect(Secret, :upsert, fn _kc, _ns, "app-env", data ->
        send(self(), {:upsert, data})
        {:ok, %{}}
      end)

      reject(Deployment, :ensure_env_from, 3)
      reject(Deployment, :restart, 4)

      assert :ok = SyncInstanceUrlEnv.call(instance)

      url = "https://git.#{domain.domain}/"
      assert_received {:upsert, %{"ROOT_URL" => ^url}}
    end
  end

  describe "call/1 — the zero-cluster gates" do
    test "a deploying row skips with zero cluster calls", %{org: _org, owner: owner} do
      instance = instance_at!(owner, url_env_version(), :deploying)

      reject(InstanceK8s, :kubeconfig_for, 1)
      reject(Secret, :get_data, 3)

      assert :ok = SyncInstanceUrlEnv.call(instance)
    end

    test "a never-deployed pending row skips with zero cluster calls", %{
      org: _org,
      owner: owner
    } do
      instance = instance_at!(owner, url_env_version(), :pending)

      reject(Secret, :get_data, 3)

      assert :ok = SyncInstanceUrlEnv.call(instance)
    end

    test "a lost row skips with zero cluster calls", %{org: _org, owner: owner} do
      instance = instance_at!(owner, url_env_version(), :lost)

      reject(Secret, :get_data, 3)

      assert :ok = SyncInstanceUrlEnv.call(instance)
    end

    test "a version naming neither env key skips with zero cluster calls", %{
      org: _org,
      owner: owner
    } do
      instance = instance_at!(owner, InstanceFixtures.app_version!(), :running)

      reject(Secret, :get_data, 3)

      assert :ok = SyncInstanceUrlEnv.call(instance)
    end

    test "a vanished instance id is :ok with zero cluster calls", %{org: _org, owner: _owner} do
      reject(Secret, :get_data, 3)

      assert :ok = SyncInstanceUrlEnv.call(Ash.UUID.generate())
    end

    test "a nil namespace on a gated row refuses with :not_deployed", %{
      org: _org,
      owner: owner
    } do
      # running but never pinned: the namespace is missing — a broken row
      instance = instance_at!(owner, url_env_version(), :running, ns: false)

      reject(Secret, :get_data, 3)

      assert {:error, :not_deployed} = SyncInstanceUrlEnv.call(instance)
    end

    test "a nil URL on an absent key is a no-op", %{org: org, owner: owner} do
      {instance, gateway, _domain} = live_custom!(org, owner, instance_url_env: "ROOT_URL")
      AccessFixtures.claim!(gateway, [])

      stub(Secret, :get_data, fn _kc, _ns, "app-env" -> {:ok, %{}} end)

      reject(Secret, :upsert, 4)
      reject(Deployment, :restart, 4)
      reject(Deployment, :ensure_env_from, 3)

      assert :ok = SyncInstanceUrlEnv.call(instance)
    end
  end

  describe "call/1 — the missing-Secret posture" do
    test "a row with env whose Secret is gone refuses with :missing — never a partial merge", %{
      org: _org,
      owner: owner
    } do
      instance =
        instance_at!(owner, url_env_version(), :running, env: %{"KEEP" => "1"})

      stub(Secret, :get_data, fn _kc, _ns, "app-env" ->
        {:error, %K8s.Error{status_code: 404, reason: :not_found, message: "gone"}}
      end)

      assert {:error, :missing} = SyncInstanceUrlEnv.call(instance)
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp url_env_version, do: InstanceFixtures.app_version!(%{instance_url_env: "ROOT_URL"})

  # A private instance walked/pinned to `status`. `:deploying` is
  # pinned directly (the funnel never walks back into it); `:lost` only
  # enters from a deployed row.
  defp instance_at!(owner, version, status, opts \\ []) do
    env = Keyword.get(opts, :env, %{})

    created =
      Instance.create!(
        %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: env},
        actor: owner
      )

    case status do
      :pending ->
        InstanceFixtures.pin!(created, exposure: :private)

      :deploying ->
        pin_deployed!(created, status: :deploying)

      :lost ->
        created
        |> pin_deployed!()
        |> InstanceFixtures.walk_to!(:running)
        |> to_status!(:lost)

      target ->
        created
        |> deployed_base!(opts)
        |> InstanceFixtures.walk_to!(target)
    end
  end

  # Deployed rows get the namespace/exposure pins; the broken-row arm
  # (a gated status without a namespace) skips the namespace.
  defp deployed_base!(created, opts) do
    if Keyword.get(opts, :ns, true) do
      pin_deployed!(created)
    else
      InstanceFixtures.pin!(created, exposure: :private)
    end
  end

  defp pin_deployed!(instance, extra \\ []) do
    base = [
      namespace: "fluxvale-app-#{instance.id}",
      deployed_at: DateTime.utc_now(),
      exposure: :private
    ]

    InstanceFixtures.pin!(instance, Keyword.merge(base, extra))
  end

  # The instance attached to the org's gateway with one live custom
  # address: a route pairing, a verified custom domain, the gateway
  # claim, and the minted hostname. The default hostname stays dark
  # (the claim names the custom domain only).
  defp live_custom!(org, owner, version_attrs, status \\ :running) do
    attrs = Map.new(version_attrs)
    version = InstanceFixtures.app_version!(attrs)
    instance = instance_at!(owner, version, status)

    gateway = AccessFixtures.gateway!(org)

    _route =
      AccessRoute.create!(
        %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
        authorize?: false
      )

    domain = AccessFixtures.verified_domain!(org)
    # the claimed gateway comes back fresh (optimistic locking) — a
    # re-claim in the test must start from it
    claimed = AccessFixtures.claim!(gateway, [domain.domain])
    AccessFixtures.mint_hostname!(instance, domain, "git")

    {instance, claimed, domain}
  end

  defp to_status!(instance, status) do
    instance
    |> Ash.Changeset.for_update(:update_status, %{status: status}, authorize?: false)
    |> Ash.update!()
  end
end
