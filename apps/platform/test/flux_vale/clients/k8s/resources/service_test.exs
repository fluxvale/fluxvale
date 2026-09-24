defmodule FluxVale.Clients.K8s.Resources.ServiceTest do
  use ExUnit.Case, async: true
  use Mimic

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Service

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  describe "create/4" do
    test "server-side-applies the manifest and returns the 201 body" do
      expect(Kubereq, :apply, fn _req, manifest, field_manager ->
        assert manifest["kind"] == "Service"
        assert manifest["metadata"]["namespace"] == "ns"
        assert field_manager == "fluxvale"

        {:ok, %{status: 201, body: %{"metadata" => %{"name" => "app"}}}}
      end)

      spec = %{port: 80, selector: %{"app" => "app"}}
      assert {:ok, %{"metadata" => %{"name" => "app"}}} = Service.create(%{}, "ns", "app", spec)
    end

    test "200 (already applied) is still ok" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm ->
        {:ok, %{status: 200, body: %{"applied" => true}}}
      end)

      assert {:ok, %{"applied" => true}} =
               Service.create(%{}, "ns", "app", %{port: 80, selector: %{}})
    end

    test "non-2xx maps to an Error" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm ->
        {:ok, %{status: 422, body: %{"message" => "invalid"}}}
      end)

      assert {:error, %Error{reason: :api_error, status_code: 422}} =
               Service.create(%{}, "ns", "app", %{port: 80, selector: %{}})
    end

    test "transport failure maps to a connection error" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:error, :transport_oops} end)

      assert {:error, %Error{reason: :connection_error}} =
               Service.create(%{}, "ns", "app", %{port: 80, selector: %{}})
    end
  end

  describe "get/3" do
    test "returns the body on 200" do
      expect(Kubereq, :get, fn _req, namespace, name ->
        assert namespace == "ns"
        assert name == "app"
        {:ok, %{status: 200, body: %{"kind" => "Service"}}}
      end)

      assert {:ok, %{"kind" => "Service"}} = Service.get(%{}, "ns", "app")
    end

    test "404 is :not_found" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = Service.get(%{}, "ns", "missing")
    end

    test "other statuses map through from_response" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 403, body: %{}}} end)

      assert {:error, %Error{reason: :forbidden}} = Service.get(%{}, "ns", "app")
    end
  end

  describe "upsert/4" do
    test "delegates to create (SSA idempotence)" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:ok, %{status: 201, body: :created}} end)

      assert {:ok, :created} = Service.upsert(%{}, "ns", "app", %{port: 80, selector: %{}})
    end
  end

  describe "delete/3" do
    test "200 deletes synchronously" do
      expect(Kubereq, :delete, fn _req, namespace, name ->
        assert namespace == "ns"
        assert name == "app"
        {:ok, %{status: 200}}
      end)

      assert :ok = Service.delete(%{}, "ns", "app")
    end

    test "202 accepts asynchronous deletion" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 202}} end)

      assert :ok = Service.delete(%{}, "ns", "app")
    end

    test "404 is :not_found, not :ok" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = Service.delete(%{}, "ns", "missing")
    end
  end

  describe "build_manifest/3" do
    test "ClusterIP with the given port and selector, targetPort defaulting to port" do
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

    test "explicit target_port is honored" do
      manifest =
        Service.build_manifest("ns", "app", %{port: 80, target_port: 3000, selector: %{}})

      assert manifest["spec"]["ports"] == [
               %{"port" => 80, "targetPort" => 3000, "protocol" => "TCP"}
             ]
    end
  end

  test "attaches the request with the right api_version/kind (routing pin)" do
    expect(Kubereq, :attach, fn _req, opts ->
      assert opts[:api_version] == "v1"
      assert opts[:kind] == "Service"
      :pinned_req
    end)

    stub(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)
    Service.get(%{}, "ns", "x")
  end
end
