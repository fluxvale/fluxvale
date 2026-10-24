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
  end

  describe "the reconciler leaves :restoring alone" do
    test "its trigger filter admits exactly the deployed/starting/running states" do
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

      assert matched == [:deploying, :starting, :running]
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
