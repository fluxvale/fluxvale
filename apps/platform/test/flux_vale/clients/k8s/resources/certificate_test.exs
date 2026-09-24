defmodule FluxVale.Clients.K8s.Resources.CertificateTest do
  use ExUnit.Case, async: true
  use Mimic

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  alias FluxVale.Clients.K8s.Error
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

    test "honors an explicit issuer_kind (:issuer → namespaced Issuer)" do
      manifest =
        Certificate.build_manifest("ns", "cert", %{
          domain: "d",
          secret_name: "s",
          issuer: "i",
          issuer_kind: :issuer
        })

      assert manifest["spec"]["issuerRef"]["kind"] == "Issuer"
    end
  end

  describe "create/4 — issuer_kind gate" do
    test "rejects an unknown kind before any cluster call (the typo case)" do
      spec = %{domain: "d", secret_name: "s", issuer: "i", issuer_kind: "Clusterissuer"}

      assert {:error, %Error{reason: :invalid_spec, message: msg}} =
               Certificate.create(nil, "ns", "cert", spec)

      assert msg =~ "Clusterissuer"
      assert msg =~ ":cluster_issuer or :issuer"
    end

    test "rejects a wrong atom, not just wrong strings" do
      spec = %{domain: "d", secret_name: "s", issuer: "i", issuer_kind: :cluster}
      assert {:error, %Error{reason: :invalid_spec}} = Certificate.create(nil, "ns", "cert", spec)
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

  defp spec do
    %{domain: "app.fluxvale.app", secret_name: "app-tls", issuer: "letsencrypt"}
  end

  describe "create/4" do
    test "applies the Certificate for a valid issuer_kind" do
      expect(Kubereq, :apply, fn _req, manifest, field_manager ->
        assert manifest["kind"] == "Certificate"
        assert manifest["spec"]["issuerRef"]["kind"] == "ClusterIssuer"
        assert field_manager == "fluxvale"
        {:ok, %{status: 201, body: manifest}}
      end)

      assert {:ok, %{"kind" => "Certificate"}} = Certificate.create(%{}, "ns", "app", spec())
    end

    test "namespace-scoped :issuer selects the Issuer kind" do
      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        assert manifest["spec"]["issuerRef"]["kind"] == "Issuer"
        {:ok, %{status: 200, body: manifest}}
      end)

      scoped = Map.put(spec(), :issuer_kind, :issuer)
      assert {:ok, _body} = Certificate.create(%{}, "ns", "app", scoped)
    end
  end

  describe "get/3" do
    test "404 is :not_found" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = Certificate.get(%{}, "ns", "missing")
    end
  end

  describe "delete/3" do
    test "200 deletes synchronously" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 200}} end)

      assert :ok = Certificate.delete(%{}, "ns", "app")
    end
  end

  describe "ready_status/3" do
    test "reads the Ready condition cert-manager sets" do
      body = %{
        "status" => %{
          "conditions" => [%{"type" => "Ready", "status" => "True"}]
        }
      }

      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 200, body: body}} end)

      assert {:ok, "True"} = Certificate.ready_status(%{}, "ns", "app")
    end

    test "a body with no status block reads as nil" do
      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: %{"kind" => "Certificate"}}}
      end)

      assert {:ok, nil} = Certificate.ready_status(%{}, "ns", "app")
    end

    test "get errors propagate" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:error, :transport_oops} end)

      assert {:error, %Error{reason: :connection_error}} =
               Certificate.ready_status(%{}, "ns", "app")
    end
  end

  test "attaches the request with the right api_version/kind (routing pin)" do
    expect(Kubereq, :attach, fn _req, opts ->
      assert opts[:api_version] == "cert-manager.io/v1"
      assert opts[:kind] == "Certificate"
      :pinned_req
    end)

    stub(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)
    Certificate.get(%{}, "ns", "x")
  end
end
