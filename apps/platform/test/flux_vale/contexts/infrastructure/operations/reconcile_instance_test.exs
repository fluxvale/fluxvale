defmodule FluxVale.Infrastructure.Operations.ReconcileInstanceTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  import ExUnit.CaptureLog

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.Pod
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceEnvSecret
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.ReconcileInstance
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    # The scheduling probe is only consulted for a not-ready workload;
    # tests that care override this with a pod list.
    stub(Pod, :list_by_labels, fn _kc, _ns, _labels -> {:ok, []} end)
    :ok
  end

  defp user do
    User.create!("reconciler-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp instance!(status, env_vars \\ %{}) do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(
        %{name: "App", app_version_id: version.id, env_vars: env_vars},
        actor: user()
      )

    # pending → deploying → … — the legal chain to `status`; namespace is
    # write-once, so it is seed-pinned after the chain.
    chain =
      case status do
        :deploying -> [:deploying]
        :starting -> [:deploying, :starting]
        :no_capacity -> [:deploying, :starting, :no_capacity]
        :running -> [:deploying, :starting, :running]
        :error -> [:deploying, :starting, :running, :error]
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

  defp pod(conditions, created_at \\ DateTime.utc_now()) do
    %{
      "metadata" => %{"creationTimestamp" => DateTime.to_iso8601(created_at)},
      "status" => %{"phase" => "Pending", "conditions" => conditions}
    }
  end

  defp deployment_status(overrides) do
    Map.merge(
      %{
        replicas: 1,
        actual_replicas: 0,
        updated: 0,
        available: 0,
        ready: 0,
        generation: 1,
        observed_generation: 1,
        conditions: []
      },
      overrides
    )
  end

  defp unschedulable_pod do
    pod([
      %{
        "type" => "PodScheduled",
        "status" => "False",
        "reason" => "Unschedulable",
        "message" => "0/3 nodes are available: 3 Insufficient cpu."
      }
    ])
  end

  defp scheduled_pod do
    pod([%{"type" => "PodScheduled", "status" => "True"}])
  end

  describe "call/1 — promotion" do
    test ":starting with readyReplicas >= replicas promotes to :running and sets anchors" do
      stub_kubeconfig()
      instance = instance!(:starting)
      ns = "fluxvale-app-#{instance.id}"

      expect(Deployment, :status, fn _kc, ^ns, "app" ->
        {:ok, deployment_status(%{actual_replicas: 1, updated: 1, ready: 1})}
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
        {:ok, deployment_status(%{actual_replicas: 1, updated: 1, ready: 1})}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :running
      assert returned.updated_at == instance.updated_at
    end

    test ":starting still progressing is a no-op" do
      stub_kubeconfig()
      instance = instance!(:starting)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, deployment_status(%{})}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :starting
    end

    test "an externally scaled-to-zero Deployment is a no-op" do
      stub_kubeconfig()
      instance = instance!(:running)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, deployment_status(%{replicas: 0})}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :running
      assert returned.updated_at == instance.updated_at
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

      # The old pod serves 1/1, but the current revision has no replica
      # (updated: 0): the deadline is a real stalled rollout, not a
      # leftover condition on a rolled-out spec.
      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok,
         %{
           replicas: 1,
           updated: 0,
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

  describe "call/1 — rollout tolerance (#776)" do
    test "a fresh ReplicaFailure during a running roll stays :running" do
      stub_kubeconfig()
      instance = instance!(:running)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok,
         %{
           replicas: 1,
           ready: 0,
           conditions: [
             conditions("Progressing", "True", reason: "ReplicaSetUpdated"),
             conditions("ReplicaFailure", "True",
               reason: "FailedCreate",
               message: "pods \"app-1\" is forbidden: exceeded quota: app-quota",
               lastTransitionTime: DateTime.to_iso8601(DateTime.utc_now())
             )
           ]
         }}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :running
      assert returned.updated_at == instance.updated_at
    end

    test "a fresh ReplicaFailure during a start stays :starting" do
      stub_kubeconfig()
      instance = instance!(:starting)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok,
         %{
           replicas: 1,
           ready: 0,
           conditions: [
             conditions("ReplicaFailure", "True",
               reason: "FailedCreate",
               message: "pods \"app-1\" is forbidden: exceeded quota: app-quota",
               lastTransitionTime: DateTime.to_iso8601(DateTime.utc_now())
             )
           ]
         }}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :starting
    end

    test "a ready workload outranks a leftover deadlined condition" do
      stub_kubeconfig()
      instance = instance!(:running)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok,
         deployment_status(%{
           actual_replicas: 1,
           updated: 1,
           ready: 1,
           conditions: [
             conditions("Progressing", "False", reason: "ProgressDeadlineExceeded"),
             conditions("ReplicaFailure", "True",
               reason: "FailedCreate",
               message: "exceeded quota",
               lastTransitionTime: DateTime.to_iso8601(DateTime.utc_now())
             )
           ]
         })}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :running
      assert returned.updated_at == instance.updated_at
    end

    test "a ready old pod does not mask a stalled current revision" do
      stub_kubeconfig()
      instance = instance!(:running)

      # The old ReplicaSet serves 1/1, but the current spec has no ready
      # replica: a real FailedCreate (not a handoff) must still error.
      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok,
         deployment_status(%{
           actual_replicas: 1,
           updated: 0,
           ready: 1,
           conditions: [conditions("Progressing", "False", reason: "ProgressDeadlineExceeded")]
         })}
      end)

      assert {:ok, errored} = ReconcileInstance.call(instance)
      assert errored.status == :error
      assert errored.failure_reason == :rollout_failed
    end

    test "an unobserved generation is not a settled revision" do
      stub_kubeconfig()
      instance = instance!(:starting)

      # The controller has not observed the new spec yet: the replica
      # counts still describe the previous generation.
      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok,
         deployment_status(%{
           generation: 2,
           observed_generation: 1,
           actual_replicas: 1,
           updated: 1,
           ready: 1
         })}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :starting
      assert returned.updated_at == instance.updated_at
    end

    test "a ready :starting row promotes despite a stale ReplicaFailure" do
      stub_kubeconfig()
      instance = instance!(:starting)

      stale = DateTime.add(DateTime.utc_now(), -301, :second)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok,
         deployment_status(%{
           actual_replicas: 1,
           updated: 1,
           ready: 1,
           conditions: [
             conditions("ReplicaFailure", "True",
               reason: "FailedCreate",
               message: "exceeded quota",
               lastTransitionTime: DateTime.to_iso8601(stale)
             )
           ]
         })}
      end)

      assert {:ok, running} = ReconcileInstance.call(instance)
      assert running.status == :running
    end

    test "a ReplicaFailure older than the stale bound lands :error with its message" do
      stub_kubeconfig()
      instance = instance!(:running)

      stale = DateTime.add(DateTime.utc_now(), -301, :second)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok,
         %{
           replicas: 1,
           ready: 0,
           conditions: [
             conditions("ReplicaFailure", "True",
               reason: "FailedCreate",
               message: "pods \"app-1\" is forbidden: exceeded quota: app-quota",
               lastTransitionTime: DateTime.to_iso8601(stale)
             )
           ]
         }}
      end)

      assert {:ok, errored} = ReconcileInstance.call(instance)
      assert errored.status == :error
      assert errored.failure_reason == :rollout_failed
      assert errored.status_message =~ "FailedCreate"
    end

    test "an unparseable failure timestamp is terminal (cannot prove it fresh)" do
      stub_kubeconfig()
      instance = instance!(:starting)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok,
         %{
           replicas: 1,
           ready: 0,
           conditions: [
             conditions("ReplicaFailure", "True",
               reason: "FailedCreate",
               message: "bad spec",
               lastTransitionTime: "not-a-time"
             )
           ]
         }}
      end)

      assert {:ok, errored} = ReconcileInstance.call(instance)
      assert errored.status == :error
      assert errored.failure_reason == :rollout_failed
    end

    test "a pod read failure never flips a progressing rollout" do
      stub_kubeconfig()
      instance = instance!(:running)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, deployment_status(%{})}
      end)

      expect(Pod, :list_by_labels, fn _kc, _ns, _labels ->
        {:error, Error.connection_error("pod list failed")}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :running
    end

    test "a pod read failure never turns a deadlined rollout into :error" do
      stub_kubeconfig()
      instance = instance!(:starting)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok,
         deployment_status(%{
           conditions: [conditions("Progressing", "False", reason: "ProgressDeadlineExceeded")]
         })}
      end)

      expect(Pod, :list_by_labels, fn _kc, _ns, _labels ->
        {:error, Error.connection_error("pod list failed")}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :starting
      assert returned.updated_at == instance.updated_at
    end
  end

  describe "call/1 — no capacity (#776)" do
    test ":starting with an unschedulable pod lands :no_capacity with the condition reason" do
      stub_kubeconfig()
      instance = instance!(:starting)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, deployment_status(%{})}
      end)

      expect(Pod, :list_by_labels, fn _kc, _ns, _labels -> {:ok, [unschedulable_pod()]} end)

      assert {:ok, waiting} = ReconcileInstance.call(instance)
      assert waiting.status == :no_capacity
      assert waiting.status_message =~ "Insufficient cpu"
      assert is_nil(waiting.failure_reason)
    end

    test ":running with an unschedulable replacement lands :no_capacity" do
      stub_kubeconfig()
      instance = instance!(:running)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, deployment_status(%{})}
      end)

      expect(Pod, :list_by_labels, fn _kc, _ns, _labels -> {:ok, [unschedulable_pod()]} end)

      assert {:ok, waiting} = ReconcileInstance.call(instance)
      assert waiting.status == :no_capacity
    end

    test "an unschedulable pod outranks a deadlined Progressing condition" do
      stub_kubeconfig()
      instance = instance!(:starting)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok,
         deployment_status(%{
           conditions: [conditions("Progressing", "False", reason: "ProgressDeadlineExceeded")]
         })}
      end)

      expect(Pod, :list_by_labels, fn _kc, _ns, _labels -> {:ok, [unschedulable_pod()]} end)

      assert {:ok, waiting} = ReconcileInstance.call(instance)
      assert waiting.status == :no_capacity
      assert waiting.status_message =~ "Insufficient cpu"
      assert is_nil(waiting.failure_reason)
    end

    test "a ready Deployment promotes :no_capacity to :running" do
      stub_kubeconfig()
      instance = instance!(:no_capacity)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, deployment_status(%{actual_replicas: 1, updated: 1, ready: 1})}
      end)

      assert {:ok, running} = ReconcileInstance.call(instance)
      assert running.status == :running
      assert running.running_since
    end

    test "a schedulable pod returns :no_capacity to :starting" do
      stub_kubeconfig()
      instance = instance!(:no_capacity)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, deployment_status(%{})}
      end)

      expect(Pod, :list_by_labels, fn _kc, _ns, _labels -> {:ok, [scheduled_pod()]} end)

      assert {:ok, starting} = ReconcileInstance.call(instance)
      assert starting.status == :starting
    end

    test "a still-unschedulable :no_capacity row is a no-op" do
      stub_kubeconfig()
      instance = instance!(:no_capacity)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, deployment_status(%{})}
      end)

      expect(Pod, :list_by_labels, fn _kc, _ns, _labels -> {:ok, [unschedulable_pod()]} end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :no_capacity
      assert returned.updated_at == instance.updated_at
    end

    test "a pod read failure keeps :no_capacity" do
      stub_kubeconfig()
      instance = instance!(:no_capacity)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, deployment_status(%{})}
      end)

      expect(Pod, :list_by_labels, fn _kc, _ns, _labels ->
        {:error, Error.connection_error("pod list failed")}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :no_capacity
    end

    test "a scaled-to-zero Deployment is left alone" do
      stub_kubeconfig()
      instance = instance!(:no_capacity)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, %{replicas: 0, ready: 0, conditions: []}}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :no_capacity
    end

    test "the newest non-terminating pod wins the scheduling probe" do
      stub_kubeconfig()
      instance = instance!(:starting)

      older_unschedulable =
        pod(
          [
            %{
              "type" => "PodScheduled",
              "status" => "False",
              "reason" => "Unschedulable",
              "message" => "0/3 nodes are available: 3 Insufficient cpu."
            }
          ],
          DateTime.add(DateTime.utc_now(), -600, :second)
        )

      newer_scheduled = scheduled_pod()

      expect(Deployment, :status, fn _kc, _ns, _n -> {:ok, deployment_status(%{})} end)

      expect(Pod, :list_by_labels, fn _kc, _ns, _labels ->
        {:ok, [older_unschedulable, newer_scheduled]}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :starting
    end

    test "a terminating unschedulable pod is ignored" do
      stub_kubeconfig()
      instance = instance!(:starting)

      terminating =
        put_in(
          unschedulable_pod(),
          ["metadata", "deletionTimestamp"],
          DateTime.to_iso8601(DateTime.utc_now())
        )

      expect(Deployment, :status, fn _kc, _ns, _n -> {:ok, deployment_status(%{})} end)
      expect(Pod, :list_by_labels, fn _kc, _ns, _labels -> {:ok, [terminating]} end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :starting
    end

    test "a transient Deployment read failure keeps :no_capacity" do
      stub_kubeconfig()
      instance = instance!(:no_capacity)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:error, Error.connection_error("api server restarting")}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :no_capacity
    end

    test "a vanished Deployment goes through the lost/missing decision" do
      stub_kubeconfig()
      instance = instance!(:no_capacity)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      stub(Namespace, :exists?, fn _kc, _ns -> {:ok, true} end)

      assert {:ok, errored} = ReconcileInstance.call(instance)
      assert errored.status == :error
      assert errored.failure_reason == :missing
    end
  end

  describe "call/1 — stuck error recovery (#776)" do
    test "a previously failed row whose Deployment is ready lands :running" do
      stub_kubeconfig()
      instance = instance!(:error)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, deployment_status(%{actual_replicas: 1, updated: 1, ready: 1})}
      end)

      assert {:ok, running} = ReconcileInstance.call(instance)
      assert running.status == :running
      assert is_nil(running.failure_reason)
      assert running.running_since
    end

    test "a healthy errored row projects its saved env before :running" do
      stub_kubeconfig()
      instance = instance!(:error, %{"FOO" => "bar"})
      ns = "fluxvale-app-#{instance.id}"

      expect(Deployment, :status, fn _kc, ^ns, _n ->
        {:ok, deployment_status(%{actual_replicas: 1, updated: 1, ready: 1})}
      end)

      expect(InstanceEnvSecret, :upsert, fn _kc, ^ns, %{"FOO" => "bar"}, [], false ->
        {:ok, %{"FOO" => "bar"}}
      end)

      expect(InstanceEnvSecret, :restart, fn _kc, ^ns, _opts -> :ok end)

      assert {:ok, running} = ReconcileInstance.call(instance)
      assert running.status == :running
      assert running.env_vars == %{"FOO" => "bar"}
    end

    test "a failed env repair leaves the error" do
      stub_kubeconfig()
      instance = instance!(:error, %{"FOO" => "bar"})

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, deployment_status(%{actual_replicas: 1, updated: 1, ready: 1})}
      end)

      expect(InstanceEnvSecret, :upsert, fn _kc, _ns, _set, _remove, _existing ->
        {:error, Error.connection_error("secret write failed")}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :error
    end

    test "a failed row with an unschedulable pod lands :no_capacity" do
      stub_kubeconfig()
      instance = instance!(:error)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, deployment_status(%{})}
      end)

      expect(Pod, :list_by_labels, fn _kc, _ns, _labels -> {:ok, [unschedulable_pod()]} end)

      assert {:ok, waiting} = ReconcileInstance.call(instance)
      assert waiting.status == :no_capacity
    end

    test "an intent-bearing failure (stop/restore/teardown) stays error" do
      stub_kubeconfig()
      instance = instance!(:running)

      {:ok, stopped_failure} =
        InstanceK8s.update_status(instance, :error, "stop failed", :stop_failed)

      assert {:ok, returned} = ReconcileInstance.call(stopped_failure)
      assert returned.status == :error
      assert returned.failure_reason == :stop_failed
    end

    test "a not-ready, scheduled workload keeps its error" do
      stub_kubeconfig()
      instance = instance!(:error)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, deployment_status(%{})}
      end)

      expect(Pod, :list_by_labels, fn _kc, _ns, _labels -> {:ok, [scheduled_pod()]} end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :error
    end

    test "a transient Deployment read failure keeps the error" do
      stub_kubeconfig()
      instance = instance!(:error)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:error, Error.connection_error("api server restarting")}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :error
    end

    test "a missing Deployment on an errored row keeps its error (never-applied shape)" do
      stub_kubeconfig()
      instance = instance!(:error)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :error
    end

    test "a scaled-to-zero Deployment is left alone" do
      stub_kubeconfig()
      instance = instance!(:error)

      expect(Deployment, :status, fn _kc, _ns, _n ->
        {:ok, %{replicas: 0, ready: 0, conditions: []}}
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :error
    end

    test "an errored row with no namespace is left alone" do
      version = InstanceFixtures.app_version!()

      instance =
        Ash.Seed.seed!(Instance, %{
          name: "Never deployed",
          slug: "never-deployed-error-0001",
          image: "example.com/app:1",
          port: 3000,
          healthcheck_path: "/",
          status: :error,
          failure_reason: :rollout_failed,
          env_vars: %{},
          app_version_id: version.id
        })

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :error
    end
  end

  describe "call/1 — wedged rollout repair (#820)" do
    # The wedge shape through the funnel: an errored row classified
    # :rollout_failed — the quota class from the staging finding that
    # started #820. :error → :error is the legal message-only re-write
    # (StatusTransition's no-op arm).
    defp rollout_failed!(env_vars \\ %{}) do
      instance = instance!(:error, env_vars)

      {:ok, errored} =
        InstanceK8s.update_status(
          instance,
          :error,
          "Deployment failed: FailedCreate: exceeded quota: app-quota",
          :rollout_failed
        )

      errored
    end

    # The grace anchor is system-written (mark_reconcile_repair stamps
    # now); an arbitrary-age anchor is a state no action can produce —
    # the sanctioned Ash.Seed case (same posture as the stale
    # deployed_at test).
    defp seed_repair_grace!(instance, seconds_ago) do
      Ash.Seed.update!(instance, %{
        reconcile_repaired_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
      })
    end

    # The lane's core deliverable: the staging wedge, reproduced. The
    # old pod serves 1/1 but the current revision has no replica
    # (updated: 0) with the generation handshake OK and the pod
    # scheduled — capacity is not the blocker, the divergent strategy
    # is: no pass can ever satisfy the readiness gate until it is
    # converged.
    test "a wedged rollout_failed row is repaired on pass 1 and promoted on pass 2" do
      stub_kubeconfig()
      instance = rollout_failed!(%{"FOO" => "bar"})
      ns = "fluxvale-app-#{instance.id}"

      # Pass 1 — the wedge: divergent strategy → restart-shaped repair.
      expect(Deployment, :status, fn _kc, ^ns, "app" ->
        {:ok, deployment_status(%{updated: 0, ready: 1})}
      end)

      expect(Pod, :list_by_labels, fn _kc, ^ns, _labels -> {:ok, [scheduled_pod()]} end)

      expect(Deployment, :strategy_diverges?, fn _kc, ^ns, "app" -> {:ok, true} end)

      expect(Deployment, :restart, fn _kc, ^ns, "app" ->
        {:ok, %{"metadata" => %{"name" => "app"}}}
      end)

      assert {:ok, repaired} = ReconcileInstance.call(instance)

      # The repair, not a status write: the row keeps its error — the
      # roll now in flight is judged on the next pass — with the grace
      # anchor stamped and no parking marker.
      assert repaired.status == :error
      assert repaired.failure_reason == :rollout_failed
      assert repaired.status_message =~ "exceeded quota"
      assert %DateTime{} = repaired.reconcile_repaired_at
      assert repaired.reconcile_parked_at == nil

      # Pass 2 — the roll landed: the converged revision is ready, so
      # the row projects its saved env and promotes (the recovery
      # promotion, unchanged by the repair arm).
      expect(Deployment, :status, fn _kc, ^ns, "app" ->
        {:ok, deployment_status(%{actual_replicas: 1, updated: 1, ready: 1})}
      end)

      expect(InstanceEnvSecret, :upsert, fn _kc, ^ns, %{"FOO" => "bar"}, [], false ->
        {:ok, %{"FOO" => "bar"}}
      end)

      expect(InstanceEnvSecret, :restart, fn _kc, ^ns, _opts -> :ok end)

      assert {:ok, running} = ReconcileInstance.call(repaired)
      assert running.status == :running
      assert is_nil(running.failure_reason)
      assert is_nil(running.reconcile_repaired_at)
      assert running.env_vars == %{"FOO" => "bar"}
    end

    test "a converged strategy within the repair grace holds the fast cadence — no restart, no park" do
      stub_kubeconfig()
      repaired = rollout_failed!()
      instance = seed_repair_grace!(repaired, 60)
      ns = "fluxvale-app-#{instance.id}"

      expect(Deployment, :status, fn _kc, ^ns, "app" ->
        {:ok, deployment_status(%{updated: 0, ready: 1})}
      end)

      expect(Deployment, :strategy_diverges?, fn _kc, ^ns, "app" -> {:ok, false} end)

      # A restart now would double-roll; a park would suppress the
      # promote. Neither may fire during the grace.
      stub(Deployment, :restart, fn _kc, _ns, _n -> flunk("no restart during the grace") end)

      assert {:ok, held} = ReconcileInstance.call(instance)
      assert held.status == :error
      assert held.updated_at == instance.updated_at
      assert held.reconcile_parked_at == nil
    end

    test "a converged strategy past the repair grace parks once, write-once" do
      stub_kubeconfig()
      repaired = rollout_failed!()
      instance = seed_repair_grace!(repaired, 400)
      ns = "fluxvale-app-#{instance.id}"

      expect(Deployment, :status, fn _kc, ^ns, "app" ->
        {:ok, deployment_status(%{updated: 0, ready: 1})}
      end)

      expect(Deployment, :strategy_diverges?, fn _kc, ^ns, "app" -> {:ok, false} end)

      expect(Deployment, :status, fn _kc, ^ns, "app" ->
        {:ok, deployment_status(%{updated: 0, ready: 1})}
      end)

      expect(Deployment, :strategy_diverges?, fn _kc, ^ns, "app" -> {:ok, false} end)

      # Pass 1 — grace expired: park (the marker that takes the row out
      # of the trigger queue).
      assert {:ok, parked} = ReconcileInstance.call(instance)
      assert %DateTime{} = parked.reconcile_parked_at
      assert parked.status == :error

      # Pass 2 — the next minute, still converged, still not ready, the
      # marker fresh: write-once-per-window, nothing more to write.
      assert {:ok, held} = ReconcileInstance.call(parked)
      assert held.updated_at == parked.updated_at
      assert held.reconcile_parked_at == parked.reconcile_parked_at
    end

    test "a converged strategy with no repair anchor parks (the never-repaired shape)" do
      stub_kubeconfig()
      instance = rollout_failed!()
      ns = "fluxvale-app-#{instance.id}"

      expect(Deployment, :status, fn _kc, ^ns, "app" ->
        {:ok, deployment_status(%{updated: 0, ready: 1})}
      end)

      expect(Deployment, :strategy_diverges?, fn _kc, ^ns, "app" -> {:ok, false} end)

      assert {:ok, parked} = ReconcileInstance.call(instance)
      assert %DateTime{} = parked.reconcile_parked_at
    end

    test "a failed repair restart earns no grace — logged, parked" do
      stub_kubeconfig()
      instance = rollout_failed!()
      ns = "fluxvale-app-#{instance.id}"

      expect(Deployment, :status, fn _kc, ^ns, "app" ->
        {:ok, deployment_status(%{updated: 0, ready: 1})}
      end)

      expect(Deployment, :strategy_diverges?, fn _kc, ^ns, "app" -> {:ok, true} end)

      expect(Deployment, :restart, fn _kc, ^ns, "app" ->
        {:error, Error.connection_error("apply conflict")}
      end)

      log =
        capture_log(fn ->
          assert {:ok, parked} = ReconcileInstance.call(instance)
          assert %DateTime{} = parked.reconcile_parked_at
          assert is_nil(parked.reconcile_repaired_at)
          assert parked.status == :error
        end)

      assert log =~ "repair restart failed"
    end

    test "a failed strategy read never parks — it would suppress a pending repair" do
      stub_kubeconfig()
      instance = rollout_failed!()
      ns = "fluxvale-app-#{instance.id}"

      expect(Deployment, :status, fn _kc, ^ns, "app" ->
        {:ok, deployment_status(%{updated: 0, ready: 1})}
      end)

      expect(Deployment, :strategy_diverges?, fn _kc, ^ns, "app" ->
        {:error, Error.connection_error("deployment get failed")}
      end)

      stub(Deployment, :restart, fn _kc, _ns, _n -> flunk("no repair off a failed read") end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :error
      assert returned.updated_at == instance.updated_at
      assert returned.reconcile_parked_at == nil
    end

    test "a failed pod read holds the pass — no repair, no park" do
      stub_kubeconfig()
      instance = rollout_failed!()
      ns = "fluxvale-app-#{instance.id}"

      expect(Deployment, :status, fn _kc, ^ns, "app" ->
        {:ok, deployment_status(%{updated: 0, ready: 1})}
      end)

      expect(Pod, :list_by_labels, fn _kc, ^ns, _labels ->
        {:error, Error.connection_error("pod list failed")}
      end)

      stub(Deployment, :strategy_diverges?, fn _kc, _ns, _n ->
        flunk("no repair off an unreadable pod list")
      end)

      assert {:ok, returned} = ReconcileInstance.call(instance)
      assert returned.status == :error
      assert returned.updated_at == instance.updated_at
      assert returned.reconcile_parked_at == nil
    end

    test "the other recoverable reasons keep the read-only no-op — no repair calls" do
      # One instance, three reason flips — instance! mints a cluster per
      # call and the create refuses a multi-cluster fleet (ADR-0006).
      stub_kubeconfig()
      row = instance!(:error)
      ns = "fluxvale-app-#{row.id}"

      for reason <- [:stuck, :missing, :start_failed] do
        {:ok, errored} = InstanceK8s.update_status(row, :error, "boom", reason)

        expect(Deployment, :status, fn _kc, ^ns, "app" ->
          {:ok, deployment_status(%{})}
        end)

        stub(Deployment, :strategy_diverges?, fn _kc, _ns, _n ->
          flunk("#{inspect(reason)} is out of the repair's scope")
        end)

        stub(Deployment, :restart, fn _kc, _ns, _n ->
          flunk("#{inspect(reason)} is out of the repair's scope")
        end)

        assert {:ok, returned} = ReconcileInstance.call(errored)
        assert returned.status == :error
        assert returned.updated_at == errored.updated_at
      end
    end

    test "an unschedulable pod wins over the repair — :no_capacity, no repair calls" do
      stub_kubeconfig()
      instance = rollout_failed!()
      ns = "fluxvale-app-#{instance.id}"

      expect(Deployment, :status, fn _kc, ^ns, "app" ->
        {:ok, deployment_status(%{updated: 0, ready: 1})}
      end)

      expect(Pod, :list_by_labels, fn _kc, ^ns, _labels -> {:ok, [unschedulable_pod()]} end)

      stub(Deployment, :strategy_diverges?, fn _kc, _ns, _n ->
        flunk("capacity outranks the repair")
      end)

      stub(Deployment, :restart, fn _kc, _ns, _n -> flunk("capacity outranks the repair") end)

      assert {:ok, waiting} = ReconcileInstance.call(instance)
      assert waiting.status == :no_capacity
    end

    test "a deploy_failed row is out of the repair entirely (owner-owned)" do
      stub_kubeconfig()
      instance = instance!(:error)

      {:ok, errored} =
        InstanceK8s.update_status(instance, :error, "deploy job failed", :deploy_failed)

      stub(Deployment, :status, fn _kc, _ns, _n ->
        flunk("deploy_failed never reaches the Deployment read")
      end)

      assert {:ok, returned} = ReconcileInstance.call(errored)
      assert returned.status == :error
      assert returned.failure_reason == :deploy_failed
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
