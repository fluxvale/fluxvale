defmodule FluxVale.Infrastructure.Operations.SweepStrandedInstancesTest do
  @moduledoc false

  # Every reachable strand shape driven through the sweeper to its
  # terminal state (#154), plus the skips that pin the boundaries: a
  # live lease, an unreadable cluster, and the reconciler's states.

  use FluxVale.DataCase, async: true
  use Mimic

  setup :verify_on_exit!

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.SweepStrandedInstances
  alias FluxVale.Repo
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Namespace, :list, fn _kc -> {:ok, []} end)

    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    {:ok, version: version}
  end

  describe "arm 1: stuck :deleting rows" do
    test "the exit run shape — teardown decided, job gone — is re-driven and hard-deleted" do
      stub_teardown_deletes()

      instance = deployed_instance!(:deleting)
      ns = "fluxvale-app-#{instance.id}"

      expect(Namespace, :delete, fn _kc, ^ns -> :ok end)

      assert {:ok, summary} = SweepStrandedInstances.call()

      assert summary.requeued_teardown_ids == [instance.id]
      assert summary.lost_ids == []
      assert summary.deleted_orphan_namespaces == []

      assert {:error, %Ash.Error.Invalid{}} = Instance.get_by_id(instance.id, authorize?: false)
    end

    test "a live teardown job holds the lease — row untouched" do
      instance = deployed_instance!(:deleting)

      seed_teardown_job!(instance.id, "available")

      assert {:ok, summary} = SweepStrandedInstances.call()

      assert summary.requeued_teardown_ids == []

      assert {:ok, still} = Instance.get_by_id(instance.id, authorize?: false)
      assert still.status == :deleting
    end

    test "a live job for a DIFFERENT instance doesn't hold this row's lease" do
      stub_teardown_deletes()

      instance = deployed_instance!(:deleting)

      # Same worker, foreign primary key — the args scoping is the
      # query's, or oban_jobs' other teardown rows would suppress every
      # re-drive in production.
      seed_teardown_job!("00000000-0000-7000-8000-000000000004", "retryable")

      assert {:ok, summary} = SweepStrandedInstances.call()

      assert summary.requeued_teardown_ids == [instance.id]

      assert {:error, %Ash.Error.Invalid{}} = Instance.get_by_id(instance.id, authorize?: false)
    end

    test "a discarded job is a lapsed lease — row re-driven" do
      stub_teardown_deletes()

      instance = deployed_instance!(:deleting)

      seed_teardown_job!(instance.id, "discarded")

      assert {:ok, summary} = SweepStrandedInstances.call()

      assert summary.requeued_teardown_ids == [instance.id]

      assert {:error, %Ash.Error.Invalid{}} = Instance.get_by_id(instance.id, authorize?: false)
    end
  end

  describe "arm 2: namespace gone while the row lives (#196)" do
    # The external-deletion simulation: the accrual-carrying row whose
    # namespace was deleted out from under it flips to :lost — metering
    # parks at detection, nothing is torn down, the owner decides.

    test "an accruing :stopped row on a dead namespace is marked :lost — the storage leak stops" do
      instance = deployed_instance!(:stopped)
      ns = "fluxvale-app-#{instance.id}"

      stub(Namespace, :exists?, fn _kc, ^ns -> {:ok, false} end)

      assert {:ok, summary} = SweepStrandedInstances.call()

      assert summary.lost_ids == [instance.id]
      assert summary.requeued_teardown_ids == []

      assert {:ok, lost} = Instance.get_by_id(instance.id, authorize?: false)
      assert lost.status == :lost
      assert lost.lost_detected_at

      # Drain-on-lost: the parked storage anchor is what stops the
      # accrual (the settle trigger keys on it).
      assert is_nil(lost.storage_metering_since)
      assert is_nil(lost.running_since)
      assert lost.unbilled_running_usec == 0

      # The platform does not destroy the row an outside actor orphaned
      # — teardown is the owner's call now.
      assert Mimic.calls(&Namespace.delete/2) == []
    end

    test ":running and ran-then-errored rows on a dead namespace are marked :lost too" do
      running = deployed_instance!(:running)
      errored = deployed_instance!(:error)

      stub(Namespace, :exists?, fn _kc, _ns -> {:ok, false} end)

      assert {:ok, summary} = SweepStrandedInstances.call()

      assert Enum.sort(summary.lost_ids) == Enum.sort([running.id, errored.id])

      assert {:ok, running_lost} = Instance.get_by_id(running.id, authorize?: false)
      assert running_lost.status == :lost
      assert is_nil(running_lost.running_since)

      assert {:ok, errored_lost} = Instance.get_by_id(errored.id, authorize?: false)
      assert errored_lost.status == :lost
    end

    test "a :lost row is this arm's output, not input — no repeated flips or teardowns" do
      instance = deployed_instance!(:stopped)

      {:ok, lost} = InstanceK8s.update_status(instance, :lost, "gone")

      stub(Namespace, :exists?, fn _kc, _ns -> {:ok, false} end)

      assert {:ok, summary} = SweepStrandedInstances.call()

      assert summary.lost_ids == []
      assert Mimic.calls(&Namespace.delete/2) == []

      assert {:ok, still} = Instance.get_by_id(lost.id, authorize?: false)
      assert still.status == :lost
    end

    test "a never-ran :error row accrues nothing and stays retryable" do
      version = InstanceFixtures.app_version!()

      instance =
        Instance.create!(%{name: "Never ran", app_version_id: version.id, env_vars: %{}},
          actor: user()
        )

      {:ok, errored} = InstanceK8s.update_status(instance, :error, "Deploy failed")

      # Namespace pinned (deploy decided) but no storage anchor: the
      # accrual boundary, not the namespace-nil guard, is what skips it.
      never_ran = InstanceFixtures.pin!(errored, namespace: "fluxvale-app-#{instance.id}")

      stub(Namespace, :exists?, fn _kc, _ns -> {:ok, false} end)

      assert {:ok, summary} = SweepStrandedInstances.call()

      assert summary.lost_ids == []

      assert {:ok, still} = Instance.get_by_id(never_ran.id, authorize?: false)
      assert still.status == :error
    end

    test "an existing namespace keeps the row" do
      instance = deployed_instance!(:stopped)

      stub(Namespace, :exists?, fn _kc, _ns -> {:ok, true} end)

      assert {:ok, summary} = SweepStrandedInstances.call()

      assert summary.lost_ids == []

      assert {:ok, still} = Instance.get_by_id(instance.id, authorize?: false)
      assert still.status == :stopped
    end

    test "an accruing row that never pinned a namespace can't be stranded on one" do
      # A row walked to :running without the deploy action (no
      # namespace pinned): the nil guard, not a cluster read, skips it.
      version = InstanceFixtures.app_version!()

      instance =
        Instance.create!(%{name: "No ns", app_version_id: version.id, env_vars: %{}},
          actor: user()
        )

      unpinned = InstanceFixtures.walk_to!(instance, :running)

      assert {:ok, summary} = SweepStrandedInstances.call()

      assert summary.lost_ids == []

      assert {:ok, still} = Instance.get_by_id(unpinned.id, authorize?: false)
      assert still.status == :running
    end

    test "a namespace-read API error never strands a row" do
      instance = deployed_instance!(:stopped)

      stub(Namespace, :exists?, fn _kc, _ns -> {:error, Error.connection_error("api down")} end)

      assert {:ok, summary} = SweepStrandedInstances.call()

      assert summary.lost_ids == []

      assert {:ok, still} = Instance.get_by_id(instance.id, authorize?: false)
      assert still.status == :stopped
    end

    test "a kubeconfig failure never strands a row (the cluster unit fails the pass)" do
      instance = deployed_instance!(:stopped)

      stub(K8s, :kubeconfig, fn nil -> {:error, Error.connection_error("no SA files")} end)

      # Arm 2 skips the row; the orphan arm's cluster read is what
      # fails — an unreachable cluster fails the sweep, never a destroy.
      assert {:error, "stranded-instance sweep failed for 1 unit(s)"} =
               SweepStrandedInstances.call()

      assert {:ok, still} = Instance.get_by_id(instance.id, authorize?: false)
      assert still.status == :stopped
    end
  end

  describe "the reconciler's states are not the sweeper's" do
    test "a :deploying row is left to the reconciler — no namespace read at all" do
      version = InstanceFixtures.app_version!()

      instance =
        Instance.create!(%{name: "In flight", app_version_id: version.id, env_vars: %{}},
          actor: user()
        )

      {:ok, deploying} = InstanceK8s.update_status(instance, :deploying, "Deploying...")

      assert {:ok, summary} = SweepStrandedInstances.call()

      assert summary.requeued_teardown_ids == []
      assert summary.lost_ids == []

      assert Mimic.calls(&Namespace.exists?/2) == []

      assert {:ok, still} = Instance.get_by_id(deploying.id, authorize?: false)
      assert still.status == :deploying
    end
  end

  describe "arm 3: orphaned namespaces" do
    test "an Active own-env orphan is deleted; live rows', Terminating, and foreign names are kept" do
      instance = deployed_instance!(:stopped)
      live_ns = "fluxvale-app-#{instance.id}"
      orphan_ns = "fluxvale-app-00000000-0000-7000-8000-000000000001"
      terminating_ns = "fluxvale-app-00000000-0000-7000-8000-000000000002"

      items = [
        ns_item(live_ns, "Active"),
        ns_item(orphan_ns, "Active"),
        ns_item(terminating_ns, "Terminating"),
        ns_item("fluxvale-platform", "Active"),
        ns_item("fluxvale-app-not-a-uuid", "Active")
      ]

      stub(Namespace, :exists?, fn _kc, _ns -> {:ok, true} end)
      stub(Namespace, :list, fn _kc -> {:ok, items} end)
      expect(Namespace, :delete, fn _kc, ^orphan_ns -> :ok end)

      assert {:ok, summary} = SweepStrandedInstances.call()

      assert summary.deleted_orphan_namespaces == [orphan_ns]
    end

    test "a 404 on the orphan delete is the goal achieved, not a failure" do
      orphan_ns = "fluxvale-app-00000000-0000-7000-8000-000000000005"
      items = [ns_item(orphan_ns, "Active")]

      stub(Namespace, :list, fn _kc -> {:ok, items} end)

      expect(Namespace, :delete, fn _kc, ^orphan_ns ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      assert {:ok, summary} = SweepStrandedInstances.call()

      assert summary.deleted_orphan_namespaces == [orphan_ns]
    end

    # #196's lesson, made permanent: the incident was prod's sweep
    # deleting staging's namespace for having no row in prod's DB (two
    # platform envs, one physical box). A foreign-env label — or no
    # label at all (pre-#196 deploys, operator-placed) — is never this
    # sweep's to delete.
    test "a foreign-env namespace is never deleted — the Oct-21 mechanism, closed" do
      foreign_ns = "fluxvale-app-00000000-0000-7000-8000-000000000006"
      items = [ns_item(foreign_ns, "Active", %{"fluxvale.io/platform-env" => "staging"})]

      stub(Namespace, :list, fn _kc -> {:ok, items} end)

      assert {:ok, summary} = SweepStrandedInstances.call()

      assert summary.deleted_orphan_namespaces == []
      assert Mimic.calls(&Namespace.delete/2) == []
    end

    test "an unlabeled instance-shaped namespace is never deleted (pre-#196 or operator-placed)" do
      unlabeled_ns = "fluxvale-app-00000000-0000-7000-8000-000000000007"
      items = [ns_item(unlabeled_ns, "Active", nil)]

      stub(Namespace, :list, fn _kc -> {:ok, items} end)

      assert {:ok, summary} = SweepStrandedInstances.call()

      assert summary.deleted_orphan_namespaces == []
      assert Mimic.calls(&Namespace.delete/2) == []
    end

    test "a failed cluster list fails the sweep; the instance arms still ran" do
      stub_teardown_deletes()

      stranded = deployed_instance!(:deleting)

      stub(Namespace, :list, fn _kc -> {:error, Error.connection_error("cluster down")} end)

      assert {:error, "stranded-instance sweep failed for 1 unit(s)"} =
               SweepStrandedInstances.call()

      assert {:error, %Ash.Error.Invalid{}} = Instance.get_by_id(stranded.id, authorize?: false)
    end

    test "a failed orphan deletion fails the pass" do
      orphan_ns = "fluxvale-app-00000000-0000-7000-8000-000000000003"
      items = [ns_item(orphan_ns, "Active")]

      stub(Namespace, :list, fn _kc -> {:ok, items} end)

      stub(Namespace, :delete, fn _kc, _n -> {:error, Error.connection_error("api down")} end)

      assert {:error, "stranded-instance sweep failed for 1 unit(s)"} =
               SweepStrandedInstances.call()
    end

    test "a crashing cluster sweep is isolated and fails the pass" do
      stub(Namespace, :list, fn _kc -> raise "list blew up" end)

      assert {:error, "stranded-instance sweep failed for 1 unit(s)"} =
               SweepStrandedInstances.call()
    end
  end

  describe "isolation" do
    test "one crashing unit is skipped and fails the pass; the others still run" do
      crashing = deployed_instance!(:stopped)
      healthy = deployed_instance!(:stopped)

      crash_ns = "fluxvale-app-#{crashing.id}"
      healthy_ns = "fluxvale-app-#{healthy.id}"

      stub(Namespace, :exists?, fn
        _kc, ^crash_ns -> raise "boom"
        _kc, ^healthy_ns -> {:ok, false}
      end)

      assert {:error, "stranded-instance sweep failed for 1 unit(s)"} =
               SweepStrandedInstances.call()

      assert {:ok, skipped} = Instance.get_by_id(crashing.id, authorize?: false)
      assert skipped.status == :stopped

      assert {:ok, healthy_lost} = Instance.get_by_id(healthy.id, authorize?: false)
      assert healthy_lost.status == :lost
    end
  end

  # An instance that ran (storage anchor set — accruing), then ended in
  # `status`; namespace pinned as the deploy action would have.
  defp deployed_instance!(status) do
    version = InstanceFixtures.app_version!()

    instance =
      Instance.create!(%{name: "App", app_version_id: version.id, env_vars: %{}}, actor: user())

    running = InstanceFixtures.walk_to!(instance, :running)

    stepped = step_to(running, status)

    InstanceFixtures.pin!(stepped, namespace: "fluxvale-app-#{instance.id}")
  end

  defp step_to(instance, :running), do: instance

  defp step_to(instance, status) do
    {:ok, stepped} = InstanceK8s.update_status(instance, status, nil)
    stepped
  end

  defp user do
    User.create!("sweep-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp stub_teardown_deletes do
    stub(Ingress, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Service, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Deployment, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Secret, :delete, fn _kc, _ns, _n -> :ok end)
    stub(PersistentVolumeClaim, :delete, fn _kc, _ns, _n -> :ok end)
    stub(NetworkPolicy, :delete, fn _kc, _ns, _n -> :ok end)
    stub(ResourceQuota, :delete, fn _kc, _ns, _n -> :ok end)
    stub(RoleBinding, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Namespace, :delete, fn _kc, _n -> :ok end)
  end

  # Oban runs testing: :inline in this suite — enqueued jobs never hit
  # oban_jobs, so a crafted row is the only representation of a lease.
  # Framework state, not resource data: Oban.Job is not an Ash resource.
  defp seed_teardown_job!(id, state) do
    trigger = AshOban.Info.oban_trigger(Instance, :teardown)
    args = %{"primary_key" => %{"id" => id}}

    args
    |> Oban.Job.new(worker: trigger.worker, queue: :deployments, state: state)
    |> Repo.insert!()
  end

  # #196: orphans carry the env label DeployInstance stamps; test env
  # is "local" (config.exs default). `labels: nil` builds an unlabeled
  # item (the pre-#196 shape).
  defp ns_item(name, phase, labels \\ %{"fluxvale.io/platform-env" => "local"}) do
    %{"metadata" => %{"name" => name, "labels" => labels}, "status" => %{"phase" => phase}}
  end
end
