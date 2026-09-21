defmodule FluxVale.Clients.K8s.Resources.PersistentVolumeClaimTest do
  use ExUnit.Case, async: true

  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim

  describe "build_manifest/3" do
    test "requests the size with ReadWriteOnce by default" do
      manifest = PersistentVolumeClaim.build_manifest("ns", "data", %{size: "1Gi"})

      assert manifest["kind"] == "PersistentVolumeClaim"
      assert manifest["spec"]["accessModes"] == ["ReadWriteOnce"]
      assert manifest["spec"]["resources"]["requests"]["storage"] == "1Gi"
    end

    test "honors an explicit access mode" do
      manifest =
        PersistentVolumeClaim.build_manifest("ns", "data", %{
          size: "1Gi",
          access_mode: "ReadWriteMany"
        })

      assert manifest["spec"]["accessModes"] == ["ReadWriteMany"]
    end
  end
end
