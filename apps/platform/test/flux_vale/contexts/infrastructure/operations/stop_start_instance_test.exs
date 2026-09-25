defmodule FluxVale.Infrastructure.Operations.StopStartInstanceTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.StartInstance
  alias FluxVale.Infrastructure.Operations.StopInstance
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    User.create!("scale-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp instance!(status) do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(%{name: "App", app_version_id: version.id, env_vars: %{}}, actor: user())

    {:ok, deploying} =
      InstanceK8s.update_status(instance, :deploying, "fluxvale-app-#{instance.id}", nil)

    {:ok, reached} =
      case status do
        :running ->
          with {:ok, starting} <- InstanceK8s.update_status(deploying, :starting, nil, nil) do
            InstanceK8s.update_status(starting, :running, nil, nil)
          end

        :stopped ->
          with {:ok, starting} <- InstanceK8s.update_status(deploying, :starting, nil, nil),
               {:ok, running} <- InstanceK8s.update_status(starting, :running, nil, nil) do
            InstanceK8s.update_status(running, :stopped, nil, nil)
          end
      end

    reached
  end

  defp stub_kubeconfig do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
  end

  describe "StopInstance" do
    test "scales to zero and lands :stopped (running anchor cleared)" do
      stub_kubeconfig()
      instance = instance!(:running)
      ns = "fluxvale-app-#{instance.id}"

      expect(Deployment, :scale, fn _kc, ^ns, "app", 0 -> {:ok, %{}} end)

      assert {:ok, stopped} = StopInstance.call(instance)
      assert stopped.status == :stopped
      assert stopped.running_since == nil
      assert stopped.storage_metering_since
    end

    test "a failed scale lands :error with the reason" do
      stub_kubeconfig()
      instance = instance!(:running)

      expect(Deployment, :scale, fn _kc, _ns, _n, 0 ->
        {:error, Error.connection_error("cluster on fire")}
      end)

      assert {:ok, errored} = StopInstance.call(instance)
      assert errored.status == :error
      assert errored.status_message =~ "Stop failed: cluster on fire"
    end

    test "a non-running instance is a no-op" do
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      instance =
        Instance.create!(%{name: "App", app_version_id: version.id, env_vars: %{}}, actor: user())

      assert {:ok, returned} = StopInstance.call(instance)
      assert returned.id == instance.id
    end
  end

  describe "StartInstance" do
    test "scales to one and lands :starting" do
      stub_kubeconfig()
      instance = instance!(:stopped)

      expect(Deployment, :scale, fn _kc, _ns, "app", 1 -> {:ok, %{}} end)

      assert {:ok, started} = StartInstance.call(instance)
      assert started.status == :starting
      assert started.status_message =~ "awaiting readiness"
    end

    test "a failed scale lands :error with the reason" do
      stub_kubeconfig()
      instance = instance!(:stopped)

      expect(Deployment, :scale, fn _kc, _ns, _n, 1 ->
        {:error, Error.from_response({:ok, %{status: 403, body: %{}}})}
      end)

      assert {:ok, errored} = StartInstance.call(instance)
      assert errored.status == :error
      assert errored.status_message =~ "Start failed"
    end

    test "a non-stopped instance is a no-op" do
      instance = instance!(:running)

      reject(Deployment, :scale, 4)

      assert {:ok, returned} = StartInstance.call(instance)
      assert returned.id == instance.id
    end
  end
end
