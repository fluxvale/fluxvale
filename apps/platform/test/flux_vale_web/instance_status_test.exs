defmodule FluxValeWeb.InstanceStatusTest do
  @moduledoc false

  # #179's vocabulary unit: every state's label + copy, every failure
  # reason's friendly message, and the taking-longer swap. The
  # denylist-across-surfaces enforcement lives in the LiveView tests;
  # this pins the copy itself.

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.NoK8sLeaks

  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxValeWeb.InstanceStatus

  describe "label/1" do
    test "maps every state-machine atom to the arc vocabulary" do
      assert InstanceStatus.label(:pending) == "Submitted"
      assert InstanceStatus.label(:deploying) == "Provisioning"
      assert InstanceStatus.label(:starting) == "Starting"
      assert InstanceStatus.label(:running) == "Running"
      assert InstanceStatus.label(:sleeping) == "Sleeping"
      assert InstanceStatus.label(:stopped) == "Stopped"
      assert InstanceStatus.label(:error) == "Failed"
      assert InstanceStatus.label(:deleting) == "Deleting"
      assert InstanceStatus.label(:lost) == "Lost"
    end
  end

  describe "in_progress?/1" do
    test "true only for the mid-provision states" do
      assert InstanceStatus.in_progress?(:deploying)
      assert InstanceStatus.in_progress?(:starting)

      # #203: sleeping is settled, not mid-provision — no spinner.
      for status <- [:pending, :running, :sleeping, :stopped, :error, :deleting, :lost] do
        refute InstanceStatus.in_progress?(status)
      end
    end
  end

  describe "message/1" do
    setup do
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()
      %{version: version}
    end

    test "progress copy for each settled state", %{version: version} do
      user = User.create!("vocab-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
      instance = InstanceFixtures.instance!(version, user)

      assert InstanceStatus.message(instance) ==
               "We've got your request — setup will begin shortly."

      running = InstanceFixtures.walk_to!(instance, :running)
      assert InstanceStatus.message(running) == "Your app is up and running."

      {:ok, stopped} = InstanceK8s.update_status(running, :stopped, nil)
      assert InstanceStatus.message(stopped) =~ "stopped"
    end

    test "in-flight copy while fresh, taking-longer copy once stale", %{version: version} do
      user = User.create!("vocab-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
      instance = InstanceFixtures.instance!(version, user)
      deploying = InstanceFixtures.walk_to!(instance, :deploying)

      # Fresh (the deploy action just set deployed_at): plain progress copy.
      fresh = InstanceFixtures.pin!(deploying, deployed_at: DateTime.utc_now())
      assert InstanceStatus.message(fresh) == "Setting up your app."

      # A provision lingering past the threshold swaps in the slow copy —
      # the state machine still says in-flight.
      stale =
        InstanceFixtures.pin!(deploying,
          deployed_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        )

      assert InstanceStatus.message(stale) ==
               "This is taking longer than usual — we're still working on it."
    end

    test "a start (no deployed_at) reads its clock off updated_at", %{version: version} do
      user = User.create!("vocab-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
      instance = InstanceFixtures.instance!(version, user)
      stopped = InstanceFixtures.walk_to!(instance, :stopped)

      # updated_at just bumped (the start's own write) → plain copy.
      {:ok, starting} = InstanceK8s.update_status(stopped, :starting, nil)
      assert InstanceStatus.message(starting) == "Starting it up."
    end

    test "every failure reason maps to friendly copy with a next step", %{version: version} do
      user = User.create!("vocab-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
      instance = InstanceFixtures.instance!(version, user)
      deployed = InstanceFixtures.walk_to!(instance, :running)

      reasons = [
        :deploy_failed,
        :stuck,
        :missing,
        :rollout_failed,
        :start_failed,
        :stop_failed,
        :teardown_failed
      ]

      for reason <- reasons do
        {:ok, failed} =
          InstanceK8s.update_status(deployed, :error, "raw operator detail: #{reason}", reason)

        message = InstanceStatus.message(failed)

        assert is_binary(message)
        assert String.contains?(message, ["Try", "try", "setting it up again"])
        # The technical detail must not ride along into user copy.
        refute message =~ "raw operator detail"
        refute_k8s_terms(message)
      end
    end

    test "an :error row without a classification (pre-#179 rows) reads the generic snag copy",
         %{version: version} do
      user = User.create!("vocab-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
      instance = InstanceFixtures.instance!(version, user)
      deployed = InstanceFixtures.walk_to!(instance, :running)

      {:ok, failed} =
        InstanceK8s.update_status(
          deployed,
          :error,
          "resourcequotas is forbidden: User system:serviceaccount cannot create"
        )

      assert InstanceStatus.message(failed) ==
               "Something went wrong on our side. Try again — if it keeps happening, we're on it."
    end

    # #196: the lost copy says what happened, that billing stopped, and
    # what to do next — without naming the platform's internals.
    test "a :lost row reads the gone copy — billing stopped, next step offered", %{
      version: version
    } do
      user = User.create!("vocab-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
      instance = InstanceFixtures.instance!(version, user)
      deployed = InstanceFixtures.walk_to!(instance, :running)

      {:ok, lost} = InstanceK8s.update_status(deployed, :lost, "Namespace gone from cluster")

      message = InstanceStatus.message(lost)

      assert message =~ "billing has been stopped"
      assert message =~ "Set it up again"
      assert message =~ "delete it"
      refute_k8s_terms(message)
      # The technical status_message never rides into user copy.
      refute message =~ "Namespace"
    end
  end
end
