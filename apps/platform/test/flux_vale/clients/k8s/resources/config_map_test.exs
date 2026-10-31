defmodule FluxVale.Clients.K8s.Resources.ConfigMapTest do
  use ExUnit.Case, async: true
  use Mimic

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.ConfigMap

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  describe "create/5" do
    test "SSA-applies the data verbatim with the managed-by labels" do
      expect(Kubereq, :apply, fn _req, manifest, field_manager ->
        assert field_manager == "fluxvale"

        assert manifest == %{
                 "apiVersion" => "v1",
                 "kind" => "ConfigMap",
                 "metadata" => %{
                   "name" => "access-dns-zones",
                   "namespace" => "fluxvale-access",
                   "labels" => %{
                     "app.kubernetes.io/managed-by" => "fluxvale",
                     "app.kubernetes.io/name" => "access-dns-zones"
                   }
                 },
                 "data" => %{"Corefile" => "# no claims\n"}
               }

        {:ok, %{status: 201, body: manifest}}
      end)

      assert {:ok, _body} =
               ConfigMap.create(%{}, "fluxvale-access", "access-dns-zones", %{
                 "Corefile" => "# no claims\n"
               })
    end

    test "extra_labels merge over the defaults" do
      manifest = ConfigMap.build_manifest("ns", "zones", %{"k" => "v"}, %{"extra" => "label"})

      assert manifest["metadata"]["labels"] == %{
               "app.kubernetes.io/managed-by" => "fluxvale",
               "app.kubernetes.io/name" => "zones",
               "extra" => "label"
             }
    end

    test "apply-on-existing (200) is success" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:ok, %{status: 200, body: %{}}} end)

      assert {:ok, %{}} = ConfigMap.create(%{}, "ns", "zones", %{"k" => "v"})
    end

    test "non-2xx maps to an Error" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:ok, %{status: 403, body: %{}}} end)

      assert {:error, %Error{reason: :forbidden}} =
               ConfigMap.create(%{}, "ns", "zones", %{"k" => "v"})
    end
  end
end
