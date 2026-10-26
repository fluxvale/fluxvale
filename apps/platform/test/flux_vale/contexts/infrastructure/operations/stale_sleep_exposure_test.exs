defmodule FluxVale.Infrastructure.Operations.StaleSleepExposureTest do
  @moduledoc false

  # ADR-0039 §7, closing ADR-0038 §6's deferred window: an idle-sweep
  # sleep that loaded a PUBLIC row must not mint a wake-mode route after
  # the row itself went PRIVATE.
  #
  # The production race, exactly: `SweepIdleInstances` reads a batch, the
  # owner's toggle commits, then the sweep calls `Instance.sleep/1` with
  # the stale struct. Before the fix, `:sleep` accepted no attributes —
  # nothing wrote or locked the row before `EdgeRoutes.apply_wake/2` — so
  # the wake route landed on a private row and stayed there (nothing at
  # rest removes it: RestoreServingEdge no-ops on private).
  #
  # These tests pin the fix, not the mechanism: the assertion is "no
  # wake-mode route is ever minted", which is what the leak actually was.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    User.create!("stale-sleep-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  # A deployed, running instance whose struct the caller holds — the
  # sweep's candidate shape.
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

  # The row goes private behind the caller's back — the toggle commits
  # after the batch read. Forced through the funnel's changeset: the
  # exposure op itself is covered by SetExposureTest and needs a cluster.
  defp privatize!(instance) do
    instance
    |> Ash.Changeset.for_update(:update_status, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:exposure, :private)
    |> Ash.update!(authorize?: false)
  end

  describe "the stale-sleep mint (ADR-0039 §7)" do
    test "a private row gets the private posture, never a wake route" do
      stub_kubeconfig()
      instance = running!()
      ns = "fluxvale-app-#{instance.id}"

      # THE RACE: the row goes private while the caller holds the
      # public struct.
      _private_row = privatize!(instance)
      assert instance.exposure == :public

      expect(Deployment, :scale, fn _kc, ^ns, "app", 0 -> {:ok, %{}} end)

      # The private posture's only cluster call: delete the app route.
      # A wake mint would call Service.create + Middleware.create +
      # Ingress.create instead, which these expectations forbid by
      # simply not stubbing them (Mimic raises on an unstubbed call to a
      # copied module).
      expect(Ingress, :delete, fn _kc, ^ns, "app-ingress" ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      assert {:ok, slept} = Instance.sleep(instance, authorize?: false)

      # The sleep succeeded against the CURRENT row, not the stale one.
      assert slept.status == :sleeping
      assert slept.exposure == :private

      # And the row on disk agrees.
      fresh = Instance.get_by_id!(instance.id, authorize?: false)
      assert fresh.status == :sleeping
      assert fresh.exposure == :private
    end

    test "a public row still sleeps into wake mode — the fix is not a blanket no-op" do
      stub_kubeconfig()
      instance = running!()
      ns = "fluxvale-app-#{instance.id}"

      expect(Deployment, :scale, fn _kc, ^ns, "app", 0 -> {:ok, %{}} end)
      expect(Service, :create, fn _kc, ^ns, "wake", _spec -> {:ok, %{}} end)
      expect(Middleware, :create, fn _kc, ^ns, _name, _spec -> {:ok, %{}} end)

      expect(Ingress, :create, fn _kc, ^ns, "app-ingress", spec ->
        assert spec.service_name == "wake"
        {:ok, %{}}
      end)

      assert {:ok, slept} = Instance.sleep(instance, authorize?: false)

      assert slept.status == :sleeping
      assert slept.exposure == :public
    end

    test "a row torn down mid-flight cancels the sleep instead of erroring the sweep" do
      stub_kubeconfig()
      instance = running!()

      # The teardown's hard delete lands inside the read-to-sleep gap.
      # The adopt step cancels with AshOban's TriggerNoLongerApplies —
      # the one correct cancel (the AdoptCurrentRow stance).
      :ok = Ash.destroy(instance, authorize?: false)

      assert {:error, _reason} = Instance.sleep(instance, authorize?: false)
      assert {:error, _not_found} = Instance.get_by_id(instance.id, authorize?: false)
    end
  end
end
