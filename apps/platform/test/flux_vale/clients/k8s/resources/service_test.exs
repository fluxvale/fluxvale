defmodule FluxVale.Clients.K8s.Resources.ServiceTest do
  use ExUnit.Case, async: true

  alias FluxVale.Clients.K8s.Resources.Service

  describe "build_manifest/3" do
    test "ClusterIP with the given port and selector" do
      manifest =
        Service.build_manifest("ns", "app", %{
          port: 80,
          selector: %{"app.kubernetes.io/name" => "app"}
        })

      assert manifest["kind"] == "Service"
      assert manifest["spec"]["type"] == "ClusterIP"
      assert manifest["spec"]["selector"] == %{"app.kubernetes.io/name" => "app"}

      assert manifest["spec"]["ports"] == [
               %{"port" => 80, "targetPort" => 80, "protocol" => "TCP"}
             ]
    end

    test "target_port defaults to port" do
      manifest =
        Service.build_manifest("ns", "app", %{port: 80, target_port: 3000, selector: %{}})

      assert manifest["spec"]["ports"] == [
               %{"port" => 80, "targetPort" => 3000, "protocol" => "TCP"}
             ]
    end
  end
end
