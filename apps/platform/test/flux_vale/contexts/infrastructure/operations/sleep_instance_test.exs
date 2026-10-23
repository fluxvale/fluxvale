defmodule FluxVale.Infrastructure.Operations.SleepInstanceTest do
  @moduledoc false

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
  alias FluxVale.Infrastructure.Operations.SleepInstance
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    User.create!("sleep-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  # running is the only sleepable state; the chain mirrors the funnel.
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

  defp stub_wake_edge do
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
  end

  describe "call/1" do
    test "scales to zero, flips the edge to wake mode, lands :sleeping" do
      stub_kubeconfig()
      stub_wake_edge()
      instance = running!()
      ns = "fluxvale-app-#{instance.id}"

      expect(Deployment, :scale, fn _kc, ^ns, "app", 0 -> {:ok, %{}} end)

      expect(Service, :create, fn _kc, ^ns, "wake", spec ->
        assert spec.external_name
        {:ok, %{}}
      end)

      assert {:ok, sleeping} = SleepInstance.call(instance)
      assert sleeping.status == :sleeping
      # Billing rides the anchors: the running interval folded, the
      # storage anchor spans the sleep (storage-only from here).
      assert sleeping.running_since == nil
      assert sleeping.storage_metering_since
    end

    test "a failed scale lands :error with the stop-failed reason" do
      stub_kubeconfig()
      instance = running!()

      expect(Deployment, :scale, fn _kc, _ns, "app", 0 ->
        {:error, Error.connection_error("cluster on fire")}
      end)

      assert {:ok, errored} = SleepInstance.call(instance)
      assert errored.status == :error
      assert errored.failure_reason == :stop_failed
      assert errored.status_message =~ "Sleep failed: cluster on fire"
    end

    test "a failed edge flip after the scale lands :stopped — honest, startable" do
      stub_kubeconfig()
      instance = running!()

      expect(Deployment, :scale, fn _kc, _ns, "app", 0 -> {:ok, %{}} end)
      stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      expect(Ingress, :create, fn _kc, _ns, _n, _spec ->
        {:error, Error.connection_error("routes refused")}
      end)

      assert {:ok, stopped} = SleepInstance.call(instance)
      assert stopped.status == :stopped
      assert stopped.status_message =~ "Slept without wake routing"
    end

    test "a kubeconfig failure lands :error before anything is touched" do
      stub(K8s, :kubeconfig, fn nil -> {:error, Error.connection_error("no SA files")} end)
      instance = running!()

      assert {:ok, errored} = SleepInstance.call(instance)
      assert errored.status == :error
      assert errored.failure_reason == :stop_failed
    end

    test "a non-running instance is a no-op (concurrent writer moved it on)" do
      instance = %Instance{status: :starting}

      assert {:ok, ^instance} = SleepInstance.call(instance)
    end
  end
end
