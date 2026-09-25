defmodule FluxVale.Clients.K8s.Resources.NetworkPolicyTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Mimic

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  describe "build_manifest/3" do
    test "default-denies ingress, re-admitting same-namespace and the edge" do
      manifest =
        NetworkPolicy.build_manifest("fluxvale-app-1", "default-deny-ingress", %{
          ingress_from_namespaces: ["traefik"]
        })

      assert manifest["kind"] == "NetworkPolicy"
      assert manifest["metadata"]["namespace"] == "fluxvale-app-1"

      spec = manifest["spec"]
      assert spec["podSelector"] == %{}
      assert spec["policyTypes"] == ["Ingress"]

      assert [%{"from" => sources}] = spec["ingress"]
      assert %{"podSelector" => %{}} in sources

      assert %{
               "namespaceSelector" => %{
                 "matchLabels" => %{"kubernetes.io/metadata.name" => "traefik"}
               }
             } in sources
    end
  end

  describe "create/4" do
    test "applies the manifest" do
      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        assert manifest["kind"] == "NetworkPolicy"
        {:ok, %{status: 201, body: manifest}}
      end)

      assert {:ok, %{"kind" => "NetworkPolicy"}} =
               NetworkPolicy.create(%{}, "fluxvale-app-1", "default-deny-ingress", %{
                 ingress_from_namespaces: ["traefik"]
               })
    end

    test "non-2xx maps to an Error" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:ok, %{status: 403, body: %{}}} end)

      assert {:error, %Error{reason: :forbidden}} =
               NetworkPolicy.create(%{}, "ns", "default-deny-ingress", %{
                 ingress_from_namespaces: ["traefik"]
               })
    end
  end

  describe "get/3" do
    test "returns the body on 200; 404 is :not_found" do
      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: %{"kind" => "NetworkPolicy"}}}
      end)

      assert {:ok, %{"kind" => "NetworkPolicy"}} =
               NetworkPolicy.get(%{}, "fluxvale-app-1", "default-deny-ingress")

      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} =
               NetworkPolicy.get(%{}, "fluxvale-app-1", "default-deny-ingress")
    end
  end

  describe "delete/3" do
    test "404 is :not_found" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} =
               NetworkPolicy.delete(%{}, "ns", "default-deny-ingress")
    end
  end
end
