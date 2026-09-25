defmodule FluxVale.Clients.K8s.Resources.ResourceQuotaTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Mimic

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.ResourceQuota

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  describe "build_manifest/3" do
    test "caps requests at the allocation and limits at 2x, storage at the PVC" do
      manifest =
        ResourceQuota.build_manifest("fluxvale-app-1", "app-quota", %{
          cpu: 0.5,
          memory: 512,
          storage: 10
        })

      assert manifest["kind"] == "ResourceQuota"
      assert manifest["metadata"]["namespace"] == "fluxvale-app-1"
      assert manifest["metadata"]["labels"]["app.kubernetes.io/managed-by"] == "fluxvale"

      hard = manifest["spec"]["hard"]
      assert hard["requests.cpu"] == "0.5"
      assert hard["requests.memory"] == "512Mi"
      assert hard["limits.cpu"] == "1.0"
      assert hard["limits.memory"] == "1024Mi"
      assert hard["requests.storage"] == "10Gi"
      assert hard["persistentvolumeclaims"] == "1"
    end
  end

  describe "create/4" do
    test "applies the manifest" do
      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        assert manifest["kind"] == "ResourceQuota"
        {:ok, %{status: 201, body: manifest}}
      end)

      assert {:ok, %{"kind" => "ResourceQuota"}} =
               ResourceQuota.create(%{}, "fluxvale-app-1", "app-quota", %{
                 cpu: 0.5,
                 memory: 256,
                 storage: 0
               })
    end

    test "non-2xx maps to an Error" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:ok, %{status: 403, body: %{}}} end)

      assert {:error, %Error{reason: :forbidden}} =
               ResourceQuota.create(%{}, "ns", "app-quota", %{cpu: 0.5, memory: 256, storage: 0})
    end
  end

  describe "get/3" do
    test "returns the body on 200" do
      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: %{"kind" => "ResourceQuota"}}}
      end)

      assert {:ok, %{"kind" => "ResourceQuota"}} =
               ResourceQuota.get(%{}, "fluxvale-app-1", "app-quota")
    end

    test "404 is :not_found" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} =
               ResourceQuota.get(%{}, "fluxvale-app-1", "app-quota")
    end
  end

  describe "delete/3" do
    test "is :ok on 200" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 200}} end)
      assert :ok = ResourceQuota.delete(%{}, "ns", "app-quota")
    end

    test "404 is :not_found" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = ResourceQuota.delete(%{}, "ns", "app-quota")
    end
  end
end
