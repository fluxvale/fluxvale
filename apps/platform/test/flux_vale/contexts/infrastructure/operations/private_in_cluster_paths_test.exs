defmodule FluxVale.Infrastructure.Operations.PrivateInClusterPathsTest do
  @moduledoc false

  # #265's in-cluster proofs: private denies the EDGE, and only the
  # edge — the platform's own paths (panel operations, the reconciler's
  # health read, backups) ride the API server and in-namespace
  # workloads, never the edge exception the policy narrows. Each path
  # is pinned here against a :private row so a future policy change
  # that breaks one fails by name.

  # async: false — full-suite runs beside other committed rows are the
  # sweep files' concern; this file stages its own rows only, but the
  # reconciler path (every-minute trigger shape) is safest unshared.

  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.BackupJob
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.ReconcileInstance
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  defp owner do
    owner =
      User.create!("private-paths-#{System.unique_integer()}@fluxvale.com", %{},
        authorize?: false
      )

    # The backup run's wallet guard reads the org's ledger — paid here;
    # the gate's own shapes live in run_instance_backup_test.
    BillingFixtures.mark_user_paid!(owner)

    owner
  end

  defp private_instance!(owner, status) do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(%{name: "App", app_version_id: version.id, env_vars: %{}}, actor: owner)

    pinned =
      InstanceFixtures.pin!(instance,
        namespace: "fluxvale-app-#{instance.id}",
        deployed_at: DateTime.utc_now(),
        exposure: :private
      )

    InstanceFixtures.walk_to!(pinned, status)
  end

  defp stub_kubeconfig do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
  end

  describe "panel operations (stop/start) still function" do
    test "stop scales to zero and start scales back — private changes neither" do
      stub_kubeconfig()
      owner = owner()
      instance = private_instance!(owner, :running)
      ns = "fluxvale-app-#{instance.id}"

      expect(Deployment, :scale, fn _kc, ^ns, "app", 0 -> {:ok, %{}} end)

      assert {:ok, stopped} = Instance.stop(instance, actor: owner)
      assert stopped.status == :stopped

      expect(Deployment, :scale, fn _kc, ^ns, "app", 1 -> {:ok, %{}} end)

      assert {:ok, started} = Instance.start(stopped, actor: owner)
      assert started.status == :starting
    end

    test "the panel's Wake works on a sleeping private instance — the owner's verb" do
      stub_kubeconfig()
      owner = owner()
      sleeping = private_instance!(owner, :sleeping)
      ns = "fluxvale-app-#{sleeping.id}"

      expect(Deployment, :scale, fn _kc, ^ns, "app", 1 -> {:ok, %{}} end)

      assert {:ok, waking} = Instance.start(sleeping, actor: owner)
      assert waking.status == :starting
    end
  end

  describe "health (the reconciler) still functions" do
    test "a ready private instance promotes :starting → :running — readiness rides the probe, not the edge" do
      stub_kubeconfig()
      owner = owner()
      instance = private_instance!(owner, :starting)
      ns = "fluxvale-app-#{instance.id}"

      expect(Deployment, :status, fn _kc, ^ns, "app" ->
        {:ok, %{replicas: 1, ready: 1, conditions: []}}
      end)

      assert {:ok, running} = ReconcileInstance.call(instance)
      assert running.status == :running
      assert running.running_since
    end
  end

  describe "backups still function" do
    test "a backup run lands its Job in the namespace — same-namespace ingress, never the edge" do
      stub_kubeconfig()
      owner = owner()
      instance = private_instance!(owner, :running)

      # The settings row is ConfigureBackups' output; here it is a
      # precondition built through the action (the repo's test-data
      # stance — run_instance_backup_test's shape).
      BackupSetting
      |> Ash.Changeset.for_create(
        :create,
        %{
          instance_id: instance.id,
          endpoint: "https://account.r2.cloudflarestorage.com",
          bucket: "fluxvale-private",
          access_key_id: "AKIAIOSFODNN7EXAMPLE"
        },
        authorize?: false
      )
      |> Ash.create!()

      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)

      expect(BackupJob, :create, fn _kc, ns, _spec ->
        assert ns == instance.namespace
        {:ok, %{}}
      end)

      assert {:ok, run} = Infrastructure.run_instance_backup(instance, :manual)
      assert run.status == :running
    end
  end
end
