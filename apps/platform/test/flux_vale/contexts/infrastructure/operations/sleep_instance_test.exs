defmodule FluxVale.Infrastructure.Operations.SleepInstanceTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.SleepInstance
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    User.create!("sleep-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  # running is the only sleepable state; the chain mirrors the funnel.
  defp running! do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(%{name: "App", app_version_id: version.id, env_vars: %{}}, actor: user())

    instance
    |> InstanceFixtures.pin!(
      namespace: "fluxvale-app-#{instance.id}",
      deployed_at: DateTime.utc_now()
    )
    |> InstanceFixtures.walk_to!(:running)
  end

  defp stub_kubeconfig do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
  end

  defp stub_wake_edge do
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
  end

  describe "call/1" do
    test "scales to zero, flips the edge to wake mode, lands :sleeping" do
      stub_kubeconfig()
      stub_wake_edge()
      instance = running!()
      ns = "fluxvale-app-#{instance.id}"

      expect(Deployment, :scale, fn _kc, ^ns, "app", 0 -> {:ok, %{}} end)

      expect(Service, :create, fn _kc, ^ns, "wake", spec ->
        assert spec.external_name
        {:ok, %{}}
      end)

      assert {:ok, sleeping} = SleepInstance.call(instance)
      assert sleeping.status == :sleeping
      # Billing rides the anchors: the running interval folded, the
      # storage anchor spans the sleep (storage-only from here).
      assert sleeping.running_since == nil
      assert sleeping.storage_metering_since
    end

    test "a failed scale lands :error with the stop-failed reason" do
      stub_kubeconfig()
      instance = running!()

      expect(Deployment, :scale, fn _kc, _ns, "app", 0 ->
        {:error, Error.connection_error("cluster on fire")}
      end)

      assert {:ok, errored} = SleepInstance.call(instance)
      assert errored.status == :error
      assert errored.failure_reason == :stop_failed
      assert errored.status_message =~ "Sleep failed: cluster on fire"
    end

    test "a failed edge flip after the scale lands :stopped — honest, startable" do
      stub_kubeconfig()
      instance = running!()

      expect(Deployment, :scale, fn _kc, _ns, "app", 0 -> {:ok, %{}} end)
      stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      expect(Ingress, :create, fn _kc, _ns, _n, _spec ->
        {:error, Error.connection_error("routes refused")}
      end)

      assert {:ok, stopped} = SleepInstance.call(instance)
      assert stopped.status == :stopped
      assert stopped.status_message =~ "Slept without wake routing"
    end

    test "a kubeconfig failure lands :error before anything is touched" do
      stub(K8s, :kubeconfig, fn nil -> {:error, Error.connection_error("no SA files")} end)
      instance = running!()

      assert {:ok, errored} = SleepInstance.call(instance)
      assert errored.status == :error
      assert errored.failure_reason == :stop_failed
    end

    test "a non-running instance is a no-op (concurrent writer moved it on)" do
      instance = %Instance{status: :starting}

      assert {:ok, ^instance} = SleepInstance.call(instance)
    end

    # #265: a private instance sleeps with NO route at the edge — no
    # wake flip mints one, so nothing external can wake it. The sleep
    # itself is ordinary economics (storage-only); always-on remains
    # the stay-awake opt-out, and the panel's Wake still works.
    test "a private instance sleeps without minting a wake route (#265)" do
      stub_kubeconfig()
      instance = running!()
      ns = "fluxvale-app-#{instance.id}"

      private = InstanceFixtures.pin!(instance, exposure: :private)

      expect(Deployment, :scale, fn _kc, ^ns, "app", 0 -> {:ok, %{}} end)

      # The private posture deletes (here: nothing to delete — the
      # 404-tolerated arm), and mints nothing.
      expect(Ingress, :delete, fn _kc, ^ns, "app-ingress" ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      reject(Ingress, :create, 4)
      reject(Service, :create, 4)
      reject(Middleware, :create, 4)

      assert {:ok, sleeping} = SleepInstance.call(private)
      assert sleeping.status == :sleeping
    end
  end

  # ----------------------------------------------------------------
  # The gateway rewrite (#273, ADR-0039 §6's sleep-side half): a
  # sleeping ATTACHED instance's serve entry must point at the
  # platform's wake endpoint. The provider runs for real against
  # stubbed K8s clients (the tailscale_test stance), so the assertion
  # is the written Secret's payload.
  # ----------------------------------------------------------------
  describe "call/1 with a gateway-attached instance (#273)" do
    defp stub_access do
      # The single-cluster placement contract the gateway create and the
      # provider both resolve through.
      InstanceFixtures.local_cluster!()

      parent = self()

      stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

      stub(Secret, :create, fn _kc, ns, name, data ->
        send(parent, {:secret_create, ns, name, data})
        {:ok, %{}}
      end)

      stub(PersistentVolumeClaim, :create, fn _kc, _ns, _name, _spec -> {:ok, %{}} end)
      stub(NetworkPolicy, :create, fn _kc, _ns, _name, _spec -> {:ok, %{}} end)
      stub(Deployment, :apply_manifest, fn _kc, _manifest -> {:ok, %{}} end)

      stub(Ingress, :delete, fn _kc, _ns, _name ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)
    end

    defp attached_pair! do
      {org, owner} = BillingFixtures.grant_free_org!()
      {:ok, _wallet} = FluxVale.Billing.ensure_wallet(org)
      {:ok, _grant} = FluxVale.Billing.grant_credits(org, 10_000, reason: :adjustment)

      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)
      {:ok, _route} = FluxVale.Infrastructure.attach_instance(gateway, instance)

      {gateway, instance}
    end

    test "sleep rewrites the gateway serve config AFTER the status write — the entry targets the platform" do
      stub_access()
      stub(Deployment, :scale, fn _kc, _ns, _name, 0 -> {:ok, %{}} end)
      {gateway, instance} = attached_pair!()
      drain_secrets()

      assert {:ok, sleeping} = SleepInstance.call(instance)
      assert sleeping.status == :sleeping

      # The regenerated config points the port at the wake endpoint and
      # NOT at the app: had the rewrite run before the :sleeping write,
      # it would have read :running and re-targeted the app (the
      # ordering this test pins).
      config = latest_serve_config()
      assert config =~ "/internal/access/#{gateway.id}/#{instance.id}"
      refute config =~ "app.#{instance.namespace}.svc.cluster.local:80"
    end

    test "a failed gateway rewrite lands :stopped with the honest message" do
      stub_access()
      stub(Deployment, :scale, fn _kc, _ns, _name, 0 -> {:ok, %{}} end)

      stub(Tailscale, :refresh_routes, fn _gateway ->
        {:error, Error.connection_error("serve refused")}
      end)

      {_gateway, instance} = attached_pair!()

      assert {:ok, stopped} = SleepInstance.call(instance)
      assert stopped.status == :stopped
      assert stopped.status_message =~ "Slept without gateway wake routing"
      assert stopped.status_message =~ "serve refused"
    end

    test "a failed pairing read lands :stopped, not a silently unwakeable :sleeping" do
      stub_access()
      stub(Deployment, :scale, fn _kc, _ns, _name, 0 -> {:ok, %{}} end)

      # A read error is not "unattached" — the catch-all error shape
      # takes the honest landing too.
      stub(AccessRoute, :get_by_instance, fn _id, _opts -> {:error, :boom} end)

      {_gateway, instance} = attached_pair!()

      assert {:ok, stopped} = SleepInstance.call(instance)
      assert stopped.status == :stopped
      assert stopped.status_message =~ "Slept without gateway wake routing"
    end

    test "an unattached instance's sleep never writes to any gateway" do
      stub_access()
      stub(Deployment, :scale, fn _kc, _ns, _name, 0 -> {:ok, %{}} end)
      {org, owner} = BillingFixtures.grant_free_org!()
      {:ok, _wallet} = FluxVale.Billing.ensure_wallet(org)
      {:ok, _grant} = FluxVale.Billing.grant_credits(org, 10_000, reason: :adjustment)
      instance = AccessFixtures.private_instance!(org, owner)

      # No serve-config write may happen — there is no pairing.
      reject(Secret, :create, 4)

      assert {:ok, sleeping} = SleepInstance.call(instance)
      assert sleeping.status == :sleeping
    end

    defp drain_secrets(acc \\ []) do
      receive do
        {:secret_create, _ns, _name, _data} = msg -> drain_secrets([msg | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    # The most recent serve config the provider wrote.
    defp latest_serve_config do
      drain_secrets()
      |> Enum.reverse()
      |> Enum.find_value(fn
        {:secret_create, _ns, name, %{"serve.json" => json}} ->
          if String.starts_with?(name, "serve-config"), do: json

        _other ->
          nil
      end)
    end
  end
end
