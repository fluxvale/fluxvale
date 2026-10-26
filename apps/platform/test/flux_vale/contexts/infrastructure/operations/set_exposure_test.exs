defmodule FluxVale.Infrastructure.Operations.SetExposureTest do
  @moduledoc false

  # #265's kill-switch, driven through the `set_exposure` action (the
  # stop/start stance: the action wires the op, so its tests pin the
  # wiring too). Cluster applies are Mimic'd; the assertion surface is
  # the call shapes and the row's honesty on failure.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.InstanceFixtures

  defp owner do
    User.create!("exposure-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  # A deployed instance at the given exposure and status — the shape a
  # toggle actually meets in production.
  defp deployed_instance!(owner, exposure, status) do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(%{name: "App", app_version_id: version.id, env_vars: %{}}, actor: owner)

    pinned =
      InstanceFixtures.pin!(instance,
        namespace: "fluxvale-app-#{instance.id}",
        deployed_at: DateTime.utc_now(),
        exposure: exposure
      )

    InstanceFixtures.walk_to!(pinned, status)
  end

  defp stub_kubeconfig do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
  end

  describe "going private (the kill-switch)" do
    test "deletes the public routes, then tightens the policy to same-namespace only" do
      stub_kubeconfig()
      owner = owner()
      instance = deployed_instance!(owner, :public, :running)
      ns = "fluxvale-app-#{instance.id}"

      expect(Ingress, :delete, fn _kc, ^ns, "app-ingress" -> :ok end)

      expect(NetworkPolicy, :create, fn _kc, ^ns, "default-deny-ingress", spec ->
        assert spec == %{ingress_from_namespaces: []}
        {:ok, %{}}
      end)

      # Nothing may be minted while going dark.
      reject(Ingress, :create, 4)
      reject(Middleware, :create, 4)

      assert {:ok, private} =
               Instance.set_exposure(instance, %{exposure: :private}, actor: owner)

      assert private.exposure == :private
    end

    test "a route-delete failure fails the action — the row stays public, the policy untouched" do
      stub_kubeconfig()
      owner = owner()
      instance = deployed_instance!(owner, :public, :running)
      ns = "fluxvale-app-#{instance.id}"

      expect(Ingress, :delete, fn _kc, ^ns, "app-ingress" ->
        {:error, Error.connection_error("delete refused")}
      end)

      # Fail-closed order: the policy tightens only after the routes
      # are gone — a refused delete means no policy write at all, and
      # the row never claims a posture the cluster didn't reach.
      reject(NetworkPolicy, :create, 4)

      assert {:error, _error} =
               Instance.set_exposure(instance, %{exposure: :private}, actor: owner)

      assert Instance.get_by_id!(instance.id, authorize?: false).exposure == :public
    end

    test "a policy failure after the routes are gone still fails the write" do
      stub_kubeconfig()
      owner = owner()
      instance = deployed_instance!(owner, :public, :running)
      ns = "fluxvale-app-#{instance.id}"

      expect(Ingress, :delete, fn _kc, ^ns, "app-ingress" -> :ok end)

      expect(NetworkPolicy, :create, fn _kc, ^ns, "default-deny-ingress", _spec ->
        {:error, Error.connection_error("policy refused")}
      end)

      assert {:error, _error} =
               Instance.set_exposure(instance, %{exposure: :private}, actor: owner)

      assert Instance.get_by_id!(instance.id, authorize?: false).exposure == :public
    end
  end

  describe "going public" do
    test "mints the serving routes and re-admits the edge" do
      stub_kubeconfig()
      owner = owner()
      instance = deployed_instance!(owner, :private, :running)
      ns = "fluxvale-app-#{instance.id}"

      expect(Middleware, :create, fn _kc, ^ns, "fluxvale-activity", _spec -> {:ok, %{}} end)

      expect(Ingress, :create, fn _kc, ^ns, "app-ingress", spec ->
        assert spec.service_name == "app"
        {:ok, %{}}
      end)

      expect(NetworkPolicy, :create, fn _kc, ^ns, "default-deny-ingress", spec ->
        assert spec == %{ingress_from_namespaces: ["traefik"]}
        {:ok, %{}}
      end)

      assert {:ok, public} = Instance.set_exposure(instance, %{exposure: :public}, actor: owner)
      assert public.exposure == :public
    end

    # A sleeping instance's public posture is the WAKE route (a visitor
    # must be able to wake it — that's the entire wake-on-use contract)
    # plus its dormant targets.
    test "a sleeping instance gets wake-mode routes, not serving ones" do
      stub_kubeconfig()
      owner = owner()
      instance = deployed_instance!(owner, :private, :sleeping)
      ns = "fluxvale-app-#{instance.id}"

      stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      expect(Ingress, :create, fn _kc, ^ns, "app-ingress", spec ->
        assert spec.service_name == "wake"
        {:ok, %{}}
      end)

      stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      assert {:ok, public} = Instance.set_exposure(instance, %{exposure: :public}, actor: owner)
      assert public.exposure == :public
    end
  end

  describe "rows the platform no longer owns cluster-side" do
    test "never-deployed rows are attribute-only — no cluster calls" do
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()
      owner = owner()

      instance =
        Instance.create!(%{name: "App", app_version_id: version.id, env_vars: %{}}, actor: owner)

      reject(K8s, :kubeconfig, 1)

      assert {:ok, private} =
               Instance.set_exposure(instance, %{exposure: :private}, actor: owner)

      assert private.exposure == :private
    end

    test ":lost rows are attribute-only — the re-deploy applies the posture" do
      stub_kubeconfig()
      owner = owner()
      instance = deployed_instance!(owner, :public, :running)

      lost = InstanceFixtures.pin!(instance, status: :lost, lost_detected_at: DateTime.utc_now())

      reject(K8s, :kubeconfig, 1)

      assert {:ok, private} = Instance.set_exposure(lost, %{exposure: :private}, actor: owner)
      assert private.exposure == :private
    end
  end
end
