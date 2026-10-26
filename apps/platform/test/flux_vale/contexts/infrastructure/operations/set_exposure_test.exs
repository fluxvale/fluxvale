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

  # The :deploy trigger's subject: namespace pinned, status :deploying.
  defp deploying_instance!(owner, exposure) do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(%{name: "App", app_version_id: version.id, env_vars: %{}}, actor: owner)

    InstanceFixtures.pin!(instance,
      status: :deploying,
      namespace: "fluxvale-app-#{instance.id}",
      deployed_at: DateTime.utc_now(),
      exposure: exposure
    )
  end

  # The deploy's full operand set (DeployInstance's own test stance:
  # default stubs, expect-ed where a test cares).
  defp stub_deploy_operands do
    stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Secret, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

    stub(Ingress, :delete, fn _kc, _ns, _name ->
      # Fresh private posture: no route exists to delete.
      {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
    end)
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
      # the row never claims a posture the cluster didn't reach. The
      # compensation re-applies the (never-deleted) public routes —
      # harmless under SSA, and it must not touch the policy either.
      stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      reject(NetworkPolicy, :create, 4)

      assert {:error, _error} =
               Instance.set_exposure(instance, %{exposure: :private}, actor: owner)

      assert Instance.get_by_id!(instance.id, authorize?: false).exposure == :public
    end

    test "a policy failure after the routes are gone restores them — the row rolls back to public, the cluster must too" do
      stub_kubeconfig()
      owner = owner()
      instance = deployed_instance!(owner, :public, :running)
      ns = "fluxvale-app-#{instance.id}"

      expect(Ingress, :delete, fn _kc, ^ns, "app-ingress" -> :ok end)

      expect(NetworkPolicy, :create, fn _kc, ^ns, "default-deny-ingress", _spec ->
        {:error, Error.connection_error("policy refused")}
      end)

      # PR #267 review finding 3: the deletes are already live and the
      # row rolls back to :public — a public row with no routes is
      # publicly persisted, unreachable, and nothing self-heals it.
      # The compensating restore re-mints them before the failure
      # returns (beacon + app route; the policy needs no restore — its
      # failed apply left the edge-admitting object in place).
      expect(Middleware, :create, fn _kc, ^ns, "fluxvale-activity", _spec -> {:ok, %{}} end)

      expect(Ingress, :create, fn _kc, ^ns, "app-ingress", spec ->
        assert spec.service_name == "app"
        {:ok, %{}}
      end)

      assert {:error, _error} =
               Instance.set_exposure(instance, %{exposure: :private}, actor: owner)

      assert Instance.get_by_id!(instance.id, authorize?: false).exposure == :public
    end

    # Both the step and its compensation can fail (one sick API
    # server): the ORIGINAL error is the actionable one — it owns the
    # retry (the panel flash; the next toggle or deploy re-converges).
    test "a compensating restore that also fails still returns the original error" do
      stub_kubeconfig()
      owner = owner()
      instance = deployed_instance!(owner, :public, :running)
      ns = "fluxvale-app-#{instance.id}"

      expect(Ingress, :delete, fn _kc, ^ns, "app-ingress" -> :ok end)

      expect(NetworkPolicy, :create, fn _kc, ^ns, "default-deny-ingress", _spec ->
        {:error, Error.connection_error("policy refused")}
      end)

      expect(Middleware, :create, fn _kc, ^ns, "fluxvale-activity", _spec ->
        {:error, Error.connection_error("restore refused")}
      end)

      # Ash wraps the raw K8s error on its way out — the ORIGINAL
      # (policy) failure is the one that must surface, not the
      # restore's.
      assert {:error, error} =
               Instance.set_exposure(instance, %{exposure: :private}, actor: owner)

      assert inspect(error) =~ "policy refused"
      refute inspect(error) =~ "restore refused"

      assert Instance.get_by_id!(instance.id, authorize?: false).exposure == :public
    end

    # The restore's mode follows the row's status (the public arm's own
    # rule): a SLEEPING instance's public posture is the wake route —
    # its restoration re-mints wake mode, not serving.
    test "a sleeping instance's compensating restore re-mints wake-mode routes" do
      stub_kubeconfig()
      owner = owner()
      instance = deployed_instance!(owner, :public, :sleeping)
      ns = "fluxvale-app-#{instance.id}"

      expect(Ingress, :delete, fn _kc, ^ns, "app-ingress" -> :ok end)

      expect(NetworkPolicy, :create, fn _kc, ^ns, "default-deny-ingress", _spec ->
        {:error, Error.connection_error("policy refused")}
      end)

      stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      expect(Ingress, :create, fn _kc, ^ns, "app-ingress", spec ->
        assert spec.service_name == "wake"
        {:ok, %{}}
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

    # The mirror of finding 3: the row rolls back to :private, so a
    # route minted above is drift (not a leak — the policy still
    # denies the edge) that the compensating delete removes.
    test "a policy failure after the routes are minted removes them again" do
      stub_kubeconfig()
      owner = owner()
      instance = deployed_instance!(owner, :private, :running)
      ns = "fluxvale-app-#{instance.id}"

      expect(Middleware, :create, fn _kc, ^ns, "fluxvale-activity", _spec -> {:ok, %{}} end)

      expect(Ingress, :create, fn _kc, ^ns, "app-ingress", _spec -> {:ok, %{}} end)

      expect(NetworkPolicy, :create, fn _kc, ^ns, "default-deny-ingress", _spec ->
        {:error, Error.connection_error("policy refused")}
      end)

      expect(Ingress, :delete, fn _kc, ^ns, "app-ingress" -> :ok end)

      assert {:error, error} = Instance.set_exposure(instance, %{exposure: :public}, actor: owner)
      assert inspect(error) =~ "policy refused"

      assert Instance.get_by_id!(instance.id, authorize?: false).exposure == :private
    end
  end

  describe "serialization with the deploy path (PR #267 review finding 4)" do
    # The exposure leak this pins: a deploy job holding a stale :public
    # record used to be able to mint the public routes + edge-admitting
    # policy AFTER set_exposure(:private) committed. Both actions now
    # carry optimistic_lock(:version) — the second writer to load the
    # row fails cleanly, its k8s never runs.
    test "an exposure flip against a moved row is refused (the deploy's write wins, the toggle retries)" do
      stub_kubeconfig()
      owner = owner()
      instance = deployed_instance!(owner, :public, :running)
      ns = "fluxvale-app-#{instance.id}"

      # The write that moves the row under the stale toggle below.
      expect(Ingress, :delete, fn _kc, ^ns, "app-ingress" -> :ok end)

      expect(NetworkPolicy, :create, fn _kc, ^ns, "default-deny-ingress", spec ->
        assert spec == %{ingress_from_namespaces: []}
        {:ok, %{}}
      end)

      assert {:ok, private} =
               Instance.set_exposure(instance, %{exposure: :private}, actor: owner)

      assert private.exposure == :private

      # The stale writer still holds the pre-toggle record: refused,
      # row untouched (Ash wraps the lock's StaleRecord in the action's
      # Invalid error class).
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               Instance.set_exposure(instance, %{exposure: :public}, actor: owner)

      fresh = Instance.get_by_id!(instance.id, authorize?: false)
      assert fresh.exposure == :private
    end

    # Round 2's semantics (P2-1): a stale deploy CONVERGES — it re-reads
    # the row inside its own transaction and deploys the row's current
    # posture. The old optimistic-lock answer would CANCEL the job
    # (AshOban's StaleRecord mapping) and strand the row :deploying.
    test "a stale deploy converges on the row's current posture after private lands — never resurrects, never cancels" do
      stub_kubeconfig()
      owner = owner()
      instance = deploying_instance!(owner, :public)

      # The toggle the deploy raced against: private commits first (its
      # own cluster apply is private's — a tolerated 404 here).
      expect(Ingress, :delete, fn _kc, _ns, "app-ingress" ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      expect(NetworkPolicy, :create, fn _kc, _ns, "default-deny-ingress", spec ->
        assert spec == %{ingress_from_namespaces: []}
        {:ok, %{}}
      end)

      assert {:ok, private} =
               Instance.set_exposure(instance, %{exposure: :private}, actor: owner)

      assert private.exposure == :private

      # The stale deploy (still holding the pre-toggle :public record):
      # it adopts the row's current truth and deploys PRIVATE end to
      # end — the workload lands, the edge stays private, no cancel.
      stub_deploy_operands()

      reject(Middleware, :create, 4)

      expect(NetworkPolicy, :create, fn _kc, _ns, "default-deny-ingress", spec ->
        assert spec == %{ingress_from_namespaces: []}
        {:ok, %{}}
      end)

      assert {:ok, deployed} =
               instance
               |> Ash.Changeset.for_update(:perform_deploy, %{}, authorize?: false)
               |> Ash.update()

      assert deployed.status == :starting
      assert deployed.exposure == :private

      fresh = Instance.get_by_id!(instance.id, authorize?: false)
      assert fresh.exposure == :private
      assert fresh.status == :starting
    end

    # The other race direction: the deploy commits its posture, and a
    # toggle loaded BEFORE it applies AFTER it — ordering converges the
    # row (the toggle's cluster apply runs against the settled deploy;
    # the row lock serialized the two windows), no refusal needed.
    test "a pre-deploy-loaded toggle applies after the deploy — ordering, not refusal" do
      stub_kubeconfig()
      owner = owner()
      instance = deploying_instance!(owner, :public)

      stub_deploy_operands()

      # The public deploy's serving edge — beacon + app route.
      stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      expect(NetworkPolicy, :create, fn _kc, _ns, "default-deny-ingress", spec ->
        assert spec == %{ingress_from_namespaces: ["traefik"]}
        {:ok, %{}}
      end)

      # The deploy commits the public posture (the stale record's own).
      assert {:ok, deployed} =
               instance
               |> Ash.Changeset.for_update(:perform_deploy, %{}, authorize?: false)
               |> Ash.update()

      assert deployed.status == :starting
      assert deployed.exposure == :public

      # The toggle, loaded BEFORE the deploy ran, applies after it —
      # the row's final posture is the toggle's, applied to a settled
      # world.
      expect(Ingress, :delete, fn _kc, _ns, "app-ingress" -> :ok end)

      expect(NetworkPolicy, :create, fn _kc, _ns, "default-deny-ingress", spec ->
        assert spec == %{ingress_from_namespaces: []}
        {:ok, %{}}
      end)

      assert {:ok, private} =
               Instance.set_exposure(instance, %{exposure: :private}, actor: owner)

      assert private.exposure == :private
    end

    # The one cancel that survives (P2-1): a row the teardown already
    # hard-deleted — AshOban's own no-longer-applies, nothing to deploy.
    test "a deploy whose row vanished cancels — teardown owns the row" do
      stub_kubeconfig()
      owner = owner()
      instance = deploying_instance!(owner, :public)

      Ash.destroy!(instance, authorize?: false)

      ghost =
        instance
        |> Ash.Changeset.for_update(:perform_deploy, %{}, authorize?: false)
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{errors: [%AshOban.Errors.TriggerNoLongerApplies{}]}} =
               ghost
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
