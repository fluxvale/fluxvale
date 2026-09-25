defmodule FluxVale.Infrastructure.Operations.TeardownInstanceTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

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
  alias FluxVale.Infrastructure.Operations.TeardownInstance
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    User.create!("teardown-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp deleting! do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(%{name: "App", app_version_id: version.id, env_vars: %{}}, actor: user())

    {:ok, deploying} =
      InstanceK8s.update_status(instance, :deploying, "fluxvale-app-#{instance.id}", nil)

    {:ok, deleting} = InstanceK8s.update_status(deploying, :deleting, nil, "Tearing down...")
    deleting
  end

  defp stub_kubeconfig do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
  end

  defp stub_deletes do
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

  describe "call/1" do
    test "deletes every resource then the namespace, then hard-deletes the row" do
      stub_kubeconfig()
      instance = deleting!()
      ns = "fluxvale-app-#{instance.id}"

      stub_deletes()

      expect(Namespace, :delete, fn _kc, ^ns -> :ok end)

      assert {:ok, returned} = TeardownInstance.call(instance)
      assert returned.id == instance.id

      assert {:error, %Ash.Error.Invalid{}} = Instance.get_by_id(instance.id, authorize?: false)
    end

    test "not_found deletes are tolerated (idempotent retries)" do
      stub_kubeconfig()
      instance = deleting!()

      stub_deletes()

      expect(Deployment, :delete, fn _kc, _ns, _n ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      # The namespace delete too — a retried teardown races namespace GC.
      expect(Namespace, :delete, fn _kc, _ns ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      assert {:ok, _deleted} = TeardownInstance.call(instance)
    end

    test "a namespace-delete failure surfaces for Oban to retry" do
      stub_kubeconfig()
      instance = deleting!()

      stub_deletes()

      expect(Namespace, :delete, fn _kc, _ns ->
        {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
      end)

      assert {:error, %Error{reason: :api_error}} = TeardownInstance.call(instance)
    end

    test "a real K8s failure returns :error for Oban to retry; the row stays :deleting" do
      stub_kubeconfig()
      instance = deleting!()

      stub_deletes()

      expect(Ingress, :delete, fn _kc, _ns, _n ->
        {:error, Error.connection_error("cluster on fire")}
      end)

      assert {:error, %Error{}} = TeardownInstance.call(instance)

      assert {:ok, _row} = Instance.get_by_id(instance.id, authorize?: false)
    end

    test "a kubeconfig failure returns :error without touching the row" do
      stub(K8s, :kubeconfig, fn nil -> {:error, Error.connection_error("no SA files")} end)

      instance = deleting!()

      assert {:error, %Error{}} = TeardownInstance.call(instance)

      assert {:ok, _row} = Instance.get_by_id(instance.id, authorize?: false)
    end

    test "a non-:deleting instance is a no-op (superseded retry)" do
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      instance =
        Instance.create!(%{name: "App", app_version_id: version.id, env_vars: %{}}, actor: user())

      assert {:ok, returned} = TeardownInstance.call(instance)
      assert returned.id == instance.id
    end
  end
end
