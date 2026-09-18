defmodule FluxVale.Clients.K8s.Resources.CertificateTest do
  use ExUnit.Case, async: true

  alias FluxVale.Clients.K8s.Resources.Certificate

  describe "build_manifest/3" do
    test "references the issuer with ClusterIssuer kind by default" do
      manifest =
        Certificate.build_manifest("ns", "cert", %{
          domain: "myapp.example.com",
          secret_name: "myapp-tls",
          issuer: "letsencrypt-production-http01"
        })

      assert manifest["apiVersion"] == "cert-manager.io/v1"
      assert manifest["spec"]["dnsNames"] == ["myapp.example.com"]
      assert manifest["spec"]["secretName"] == "myapp-tls"

      assert manifest["spec"]["issuerRef"] == %{
               "name" => "letsencrypt-production-http01",
               "kind" => "ClusterIssuer"
             }
    end

    test "honors an explicit issuer_kind" do
      manifest =
        Certificate.build_manifest("ns", "cert", %{
          domain: "d",
          secret_name: "s",
          issuer: "i",
          issuer_kind: "Issuer"
        })

      assert manifest["spec"]["issuerRef"]["kind"] == "Issuer"
    end
  end

  describe "find_ready/1" do
    test "extracts the Ready condition status" do
      conditions = [%{"type" => "Ready", "status" => "True"}]
      assert Certificate.find_ready(conditions) == "True"
    end

    test "extracts False, not just True" do
      conditions = [%{"type" => "Ready", "status" => "False"}]
      assert Certificate.find_ready(conditions) == "False"
    end

    test "nil when Ready is absent, malformed, or the list is empty" do
      assert Certificate.find_ready([%{"type" => "Other", "status" => "True"}]) == nil
      assert Certificate.find_ready([%{"type" => "Ready"}]) == nil
      assert Certificate.find_ready([]) == nil
    end
  end
end
