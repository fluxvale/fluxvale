defmodule FluxVale.Infrastructure.Operations.RestoringStateTest do
  @moduledoc """
  #222 (ADR-0037 §5): the `:restoring` state's neighbours. A restore owns
  the instance while it runs, and every other automation must leave it
  alone — these pin the three places that decide that, so a later edit to
  any of them fails here instead of silently corrupting a restore.
  """

  use FluxVale.DataCase, async: true
  use Mimic

  alias Ash.Filter.Runtime
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.ReconcileInstance
  alias FluxVale.Infrastructure.Operations.SweepIdleInstances
  alias FluxVale.Infrastructure.Types.BackupRunKind
  alias FluxVale.Infrastructure.Types.InstanceFailureReason
  alias FluxVale.Infrastructure.Types.InstanceStatus
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  defp user do
    User.create!("restoring-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  # A deployed instance really in :restoring (through the funnel), re-read
  # so callers hold the persisted row.
  defp restoring_instance! do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(
        %{
          name: "Restoring #{System.unique_integer()}",
          app_version_id: version.id,
          env_vars: %{}
        },
        actor: user()
      )

    running =
      instance
      |> InstanceFixtures.pin!(
        namespace: "fluxvale-app-#{instance.id}",
        deployed_at: DateTime.utc_now()
      )
      |> InstanceFixtures.walk_to!(:running)

    {:ok, _restoring} = InstanceK8s.update_status(running, :restoring, nil)

    Instance.get_by_id!(instance.id, authorize?: false)
  end

  # A deployed row landed in :error through the funnel — the shape the
  # reconcile trigger's failure-reason gate has to filter in SQL.
  defp errored_instance!(reason) do
    version = InstanceFixtures.app_version!()

    instance =
      Instance.create!(
        %{
          name: "Errored #{System.unique_integer()}",
          app_version_id: version.id,
          env_vars: %{}
        },
        actor: user()
      )

    running =
      instance
      |> InstanceFixtures.pin!(
        namespace: "fluxvale-app-#{instance.id}",
        deployed_at: DateTime.utc_now()
      )
      |> InstanceFixtures.walk_to!(:running)

    {:ok, errored} = InstanceK8s.update_status(running, :error, "boom", reason)
    errored
  end

  describe "the enums (text-stored, code-only)" do
    test ":restoring is an Instance status" do
      assert :restoring in InstanceStatus.values()
    end

    test ":restore is a run kind — the same rows carry both directions" do
      assert :restore in BackupRunKind.values()
      assert :scheduled in BackupRunKind.values()
      assert :manual in BackupRunKind.values()
    end

    test ":restore_failed is a failure reason" do
      assert :restore_failed in InstanceFailureReason.values()
    end

    test "the recoverable set is the unintended failures (#776)" do
      assert InstanceFailureReason.recoverable() == [
               :stuck,
               :missing,
               :rollout_failed,
               :start_failed
             ]
    end
  end

  describe "the reconciler leaves :restoring alone" do
    test "its trigger filter admits the reconciled states" do
      trigger = AshOban.Info.oban_trigger(Instance, :reconcile_status)
      query = Ash.Query.filter(Instance, trigger.where)
      domain = Infrastructure

      # The filter is the whole guarantee: a :restoring row is never
      # picked up, so a half-written volume is never mirrored into
      # :running (and never demoted mid-restore). Enumerate every status
      # so a future state is a conscious decision here.
      matched =
        for status <- InstanceStatus.values(),
            row = %Instance{id: Ash.UUID.generate(), status: status},
            {:ok, [_match]} <- [Runtime.filter_matches(domain, [row], query.filter)],
            do: status

      assert matched == [:deploying, :starting, :no_capacity, :running, :error]
    end

    test "the trigger admits only the recoverable error reasons (#776)" do
      trigger = AshOban.Info.oban_trigger(Instance, :reconcile_status)
      query = Ash.Query.filter(Instance, trigger.where)
      domain = Infrastructure

      admitted? = fn reason ->
        row = %Instance{id: Ash.UUID.generate(), status: :error, failure_reason: reason}

        match?(
          {:ok, [_match]},
          Runtime.filter_matches(domain, [row], query.filter)
        )
      end

      for reason <- [nil, :stuck, :missing, :rollout_failed, :start_failed] do
        assert admitted?.(reason), "expected #{inspect(reason)} to be admitted"
      end

      for reason <- [:deploy_failed, :stop_failed, :restore_failed, :teardown_failed] do
        refute admitted?.(reason), "expected #{inspect(reason)} to stay out"
      end
    end

    test "the trigger filter's SQL form queues recoverable errors, not intent-bearing ones" do
      # One cluster for all three rows — the create resolves the single
      # cluster row (more than one is ADR-0006's refused shape).
      InstanceFixtures.local_cluster!()
      trigger = AshOban.Info.oban_trigger(Instance, :reconcile_status)

      recoverable = errored_instance!(:rollout_failed)
      legacy = errored_instance!(nil)
      intent_bearing = errored_instance!(:stop_failed)

      query =
        Instance
        |> Ash.Query.filter(trigger.where)
        |> Ash.Query.sort(:id)

      {:ok, rows} = Ash.read(query, authorize?: false)
      ids = Enum.map(rows, & &1.id)

      assert recoverable.id in ids
      assert legacy.id in ids
      refute intent_bearing.id in ids
    end

    test "a direct reconcile call on a :restoring row is a no-op" do
      # Belt and braces beside the trigger filter: the operation's own
      # guard clause skips the state, so even a direct call does nothing.
      reject(K8s, :kubeconfig, 1)

      restoring = restoring_instance!()
      assert {:ok, returned} = ReconcileInstance.call(restoring)
      assert returned.status == :restoring
    end
  end

  describe "Start/Stop leave :restoring alone" do
    test "start is rejected by the action's status guard" do
      restoring = restoring_instance!()

      reject(K8s, :kubeconfig, 1)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.start(restoring, authorize?: false)

      assert Enum.any?(errors, &(&1.message =~ "cannot start instance in restoring"))
    end

    test "stop is rejected by the action's status guard" do
      restoring = restoring_instance!()

      reject(K8s, :kubeconfig, 1)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.stop(restoring, authorize?: false)

      assert Enum.any?(errors, &(&1.message =~ "cannot stop instance in restoring"))
    end

    test "sleep is rejected likewise — the sweep can never park a restoring row" do
      restoring = restoring_instance!()

      reject(K8s, :kubeconfig, 1)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.sleep(restoring, authorize?: false)

      assert Enum.any?(errors, &(&1.message =~ "cannot sleep instance in restoring"))
    end
  end

  describe "the idle sweep leaves :restoring alone" do
    test "a restoring row is never a sleep candidate, however stale its marker" do
      # A marker far past the idle threshold: if the candidate filter
      # admitted :restoring at all, this row would sleep mid-restore.
      cold = DateTime.add(DateTime.utc_now(), -7200, :second)
      stale = InstanceFixtures.pin!(restoring_instance!(), last_used_at: cold)

      refute SweepIdleInstances.still_idle?(stale)
    end

    test "the sweep scales nothing while an instance is restoring" do
      restoring_instance!()

      reject(K8s, :kubeconfig, 1)
      reject(Deployment, :scale, 4)

      assert {:ok, summary} = SweepIdleInstances.call()
      assert summary.slept_ids == []
    end
  end
end
