defmodule FluxVale.Clients.K8s.Resources.RoleBindingTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Mimic

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.RoleBinding

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  describe "build_manifest/3" do
    test "binds the platform SA to the workload ClusterRole in the namespace" do
      manifest =
        RoleBinding.build_manifest("fluxvale-app-1", "fluxvale-platform", %{
          service_account: "fluxvale-platform",
          service_account_namespace: "fluxvale-dev",
          role: "fluxvale-platform-workload"
        })

      assert manifest["kind"] == "RoleBinding"
      assert manifest["metadata"]["namespace"] == "fluxvale-app-1"

      assert manifest["roleRef"] == %{
               "apiGroup" => "rbac.authorization.k8s.io",
               "kind" => "ClusterRole",
               "name" => "fluxvale-platform-workload"
             }

      assert manifest["subjects"] == [
               %{
                 "kind" => "ServiceAccount",
                 "name" => "fluxvale-platform",
                 "namespace" => "fluxvale-dev"
               }
             ]
    end
  end

  describe "create/4" do
    test "applies the manifest" do
      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        assert manifest["kind"] == "RoleBinding"
        {:ok, %{status: 201, body: manifest}}
      end)

      assert {:ok, %{"kind" => "RoleBinding"}} =
               RoleBinding.create(%{}, "fluxvale-app-1", "fluxvale-platform", %{
                 service_account: "fluxvale-platform",
                 service_account_namespace: "fluxvale-dev",
                 role: "fluxvale-platform-workload"
               })
    end

    test "non-2xx maps to an Error" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:ok, %{status: 403, body: %{}}} end)

      assert {:error, %Error{reason: :forbidden}} =
               RoleBinding.create(%{}, "ns", "fluxvale-platform", %{
                 service_account: "fluxvale-platform",
                 service_account_namespace: "fluxvale-dev",
                 role: "fluxvale-platform-workload"
               })
    end
  end

  describe "get/3" do
    test "returns the body on 200; 404 is :not_found" do
      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: %{"kind" => "RoleBinding"}}}
      end)

      assert {:ok, %{"kind" => "RoleBinding"}} =
               RoleBinding.get(%{}, "fluxvale-app-1", "fluxvale-platform")

      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} =
               RoleBinding.get(%{}, "fluxvale-app-1", "fluxvale-platform")
    end
  end

  describe "delete/3" do
    test "404 is :not_found" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} =
               RoleBinding.delete(%{}, "ns", "fluxvale-platform")
    end
  end
end
