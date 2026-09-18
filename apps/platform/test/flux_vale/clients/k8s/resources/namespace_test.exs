defmodule FluxVale.Clients.K8s.Resources.NamespaceTest do
  use ExUnit.Case, async: true

  alias FluxVale.Clients.K8s.Resources.Namespace

  describe "build_manifest/2" do
    test "applies the managed-by label by default" do
      manifest = Namespace.build_manifest("fluxvale-app-abc123", %{})

      assert manifest["kind"] == "Namespace"
      assert manifest["metadata"]["name"] == "fluxvale-app-abc123"
      assert manifest["metadata"]["labels"] == %{"app.kubernetes.io/managed-by" => "fluxvale"}
    end

    test "merges caller labels over the standard ones" do
      manifest = Namespace.build_manifest("ns", %{labels: %{"fluxvale/instance" => "abc"}})

      assert manifest["metadata"]["labels"] == %{
               "app.kubernetes.io/managed-by" => "fluxvale",
               "fluxvale/instance" => "abc"
             }
    end
  end
end
