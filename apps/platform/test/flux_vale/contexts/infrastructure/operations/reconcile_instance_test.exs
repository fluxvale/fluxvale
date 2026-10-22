defmodule FluxVale.Infrastructure.Operations.ReconcileInstanceTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.ReconcileInstance
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    User.create!("reconciler-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp instance!(status) do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(%{name: "App", app_version_id: version.id, env_vars: %{}}, actor: user())

    # pending → deploying → … — the legal chain to `status`; namespace is
    # write-once, so it is seed-pinned after the chain.
    chain =
      case status do
        :deploying -> [:deploying]
        :starting -> [:deploying, :starting]
        :running -> [:deploying, :starting, :running]
        :stopped -> [:deploying, :starting, :running, :stopped]
      end

    reached = reach!(instance, chain)

    InstanceFixtures.pin!(reached,
      namespace: "fluxvale-app-#{instance.id}",
      deployed_at: DateTime.utc_now()
    )
  end

  defp reach!(instance, statuses) do
    Enum.reduce(statuses, instance, fn status, acc ->
      {:ok, updated} = InstanceK8s.update_status(acc, status, nil)
      updated
    end)
  end

  defp stub_kubeconfig do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
  end

  defp conditions(type, status, extra) do
    extra_map = Map.new(extra, fn {key, value} -> {Atom.to_string(key), value} end)
    Map.merge(%{"type" => type, "status" => status}, extra_map)
  end

  describe "call/1 — promotion" do
    test ":starting with readyReplicas >= replicas promotes to :running and sets anchors" do
      stub_kubeconfig()
      instance = instance!(:starting)
      ns = "fluxvale-app-#{instance.id}"

      expect(Deployment, :status, fn _kc, ^ns, "app" ->
        {:ok, %{replicas: 1, ready: 1, conditions: []}}
      end)

      assert {:ok, running} = ReconcileInstance.call(instance)
      assert running.status == :running
      assert running.running_since
      assert running.storage_metering_since
    end

    test ":running with ready replicas is a no-op (no churn)" do
      stub_kubeconfig()
      instance = instance!(:running)

      # running_since untouched from the update_status writes — assert via
      # the unchanged state, not timestamps.
      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, %{replicas: 1, ready: 1, conditions: []}}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :running
      assert returned.updated_at == instance.updated_at
    end

    test ":starting still progressing is a no-op" do
      stub_kubeconfig()
      instance = instance!(:starting)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, %{replicas: 1, ready: 0, conditions: []}}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :starting
    end
  end

  describe "call/1 — demotion" do
    test "a True ReplicaFailure condition lands :error with its message" do
      stub_kubeconfig()
      instance = instance!(:starting)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok,
         %{
           replicas: 1,
           ready: 0,
           conditions: [
             conditions("ReplicaFailure", "True",
               reason: "CrashLoopBackOff",
               message: "back-off 5m restarting failed container"
             )
           ]
         }}
      end)

      assert {:ok, errored} = ReconcileInstance.call(instance)
      assert errored.status == :error
      assert errored.status_message =~ "CrashLoopBackOff: back-off"
      assert errored.failure_reason == :rollout_failed
    end

    test "a ProgressDeadlineExceeded Progressing condition lands :error" do
      stub_kubeconfig()
      instance = instance!(:running)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok,
         %{
           replicas: 1,
           ready: 1,
           conditions: [
             conditions("Progressing", "False", %{reason: "ProgressDeadlineExceeded"})
           ]
         }}
      end)

      assert {:ok, errored} = ReconcileInstance.call(instance)
      assert errored.status == :error
      assert errored.status_message =~ "ProgressDeadlineExceeded"
      assert errored.failure_reason == :rollout_failed
    end

    test "non-failure conditions (e.g. Progressing True) never demote" do
      stub_kubeconfig()
      instance = instance!(:starting)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok,
         %{
           replicas: 1,
           ready: 0,
           conditions: [
             conditions("Progressing", "True", []),
             conditions("Available", "False", [])
           ]
         }}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :starting
    end

    test "a reason-less failed rollout reports the stalled message" do
      stub_kubeconfig()
      instance = instance!(:starting)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, %{replicas: 1, ready: 0, conditions: [conditions("ReplicaFailure", "True", [])]}}
      end)

      assert {:ok, errored} = ReconcileInstance.call(instance)
      assert errored.status == :error
      assert errored.status_message == "Deployment failed: rollout stalled"
      assert errored.failure_reason == :rollout_failed
    end

    test "a vanished Deployment in a live namespace lands :error" do
      stub_kubeconfig()
      instance = instance!(:starting)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      stub(Namespace, :exists?, fn _kc, _ns -> {:ok, true} end)

      assert {:ok, errored} = ReconcileInstance.call(instance)
      assert errored.status == :error
      assert errored.status_message =~ "Deployment not found in cluster"
      assert errored.failure_reason == :missing
    end

    # #196: the external-deletion simulation — namespace and Deployment
    # both gone is the actor-outside-the-platform signature. Detection
    # must transition the row to :lost and stop metering at that
    # moment, not keep accruing on a dead row.
    test "a vanished Deployment with a vanished namespace lands :lost with metering parked" do
      stub_kubeconfig()
      instance = instance!(:running)
      ns = "fluxvale-app-#{instance.id}"

      expect(Deployment, :status, fn _kc, ^ns, "app" ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      expect(Namespace, :exists?, fn _kc, ^ns -> {:ok, false} end)

      assert {:ok, lost} = ReconcileInstance.call(instance)

      assert lost.status == :lost
      assert lost.status_message =~ "marked lost"
      assert is_nil(lost.failure_reason)
      assert lost.lost_detected_at

      # The drain-on-lost guard: every anchor parked, atomically with
      # the flip — nothing settles or accrues past detection.
      assert is_nil(lost.running_since)
      assert lost.unbilled_running_usec == 0
      assert is_nil(lost.storage_metering_since)
    end

    test "a forbidden Deployment read in a deleted namespace lands :lost — the 403-not-404 shape (#196)" do
      stub_kubeconfig()
      instance = instance!(:running)
      ns = "fluxvale-app-#{instance.id}"

      # The incident's exact shape: the per-namespace RoleBinding dies
      # with the namespace, so the Deployment GET answers 403, not 404 —
      # the old code's `:not_found`-only match silently no-op'd on this
      # every minute for 90+ minutes.
      expect(Deployment, :status, fn _kc, ^ns, "app" ->
        {:error, Error.from_response({:ok, %{status: 403, body: %{"reason" => "Forbidden"}}})}
      end)

      expect(Namespace, :exists?, fn _kc, ^ns -> {:ok, false} end)

      assert {:ok, lost} = ReconcileInstance.call(instance)

      assert lost.status == :lost
      assert lost.lost_detected_at
      assert is_nil(lost.running_since)
      assert lost.unbilled_running_usec == 0
      assert is_nil(lost.storage_metering_since)
    end

    test "a forbidden Deployment read in a live namespace is an RBAC anomaly, not a loss" do
      stub_kubeconfig()
      instance = instance!(:running)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:error, Error.from_response({:ok, %{status: 403, body: %{"reason" => "Forbidden"}}})}
      end)

      stub(Namespace, :exists?, fn _kc, _ns -> {:ok, true} end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :running
    end

    test "an unreadable namespace read keeps the conservative :error (never claim lost on a failed read)" do
      stub_kubeconfig()
      instance = instance!(:running)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      stub(Namespace, :exists?, fn _kc, _ns ->
        {:error, Error.connection_error("ns read failed")}
      end)

      assert {:ok, errored} = ReconcileInstance.call(instance)
      assert errored.status == :error
      assert errored.failure_reason == :missing
    end
  end

  describe "call/1 — resilience" do
    test "a transient K8s read failure never flips status" do
      stub_kubeconfig()
      instance = instance!(:starting)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:error, Error.connection_error("api server restarting")}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :starting
    end

    test "a kubeconfig failure never flips status" do
      stub(K8s, :kubeconfig, fn nil -> {:error, Error.connection_error("no SA files")} end)

      instance = instance!(:starting)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :starting
    end
  end

  describe "call/1 — stale deploy timeout" do
    test "a :deploying instance older than the timeout lands :error" do
      # deployed_at is system-written by the deploy action; the stale
      # branch needs one older than the action can produce in a test —
      # sanctioned Ash.seed! use (repo convention).
      version = InstanceFixtures.app_version!()

      instance =
        Ash.Seed.seed!(Instance, %{
          name: "Stale",
          slug: "stale-app-0001",
          image: "example.com/app:1",
          port: 3000,
          healthcheck_path: "/",
          status: :deploying,
          namespace: "fluxvale-app-stale",
          deployed_at: DateTime.add(DateTime.utc_now(), -600, :second),
          env_vars: %{},
          app_version_id: version.id
        })

      assert {:ok, errored} = ReconcileInstance.call(instance)
      assert errored.status == :error
      assert errored.status_message =~ "timed out"
      assert errored.failure_reason == :stuck
    end

    test "a fresh :deploying instance is the deploy job's state — no-op" do
      instance = instance!(:deploying)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :deploying
    end

    test "a :deploying instance with no deployed_at yet is never stale" do
      # deployed_at is system-written by the deploy action; the not-yet-set
      # window is only observable via seed (sanctioned).
      version = InstanceFixtures.app_version!()

      instance =
        Ash.Seed.seed!(Instance, %{
          name: "Unstamped",
          slug: "unstamped-app-0002",
          image: "example.com/app:1",
          port: 3000,
          healthcheck_path: "/",
          status: :deploying,
          namespace: "fluxvale-app-unstamped",
          env_vars: %{},
          app_version_id: version.id
        })

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :deploying
    end
  end

  describe "call/1 — other states" do
    test ":stopped instances reconcile to themselves" do
      instance = instance!(:stopped)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.id == instance.id
    end
  end
end
