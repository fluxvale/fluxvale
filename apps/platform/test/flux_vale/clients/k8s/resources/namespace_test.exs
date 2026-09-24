defmodule FluxVale.Clients.K8s.Resources.NamespaceTest do
  use ExUnit.Case, async: true
  use Mimic

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Namespace

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  describe "list/1" do
    test "returns the items of a NamespaceList" do
      expect(Kubereq, :list, fn _req ->
        {:ok, %{status: 200, body: %{"items" => [%{"kind" => "Namespace"}]}}}
      end)

      assert {:ok, [%{"kind" => "Namespace"}]} = Namespace.list(%{})
    end

    test "malformed 200 body is a validation error, not a from_response crash" do
      expect(Kubereq, :list, fn _req -> {:ok, %{status: 200, body: %{"unexpected" => true}}} end)

      assert {:error, %Error{reason: :validation_error}} = Namespace.list(%{})
    end

    test "non-200 maps to an Error" do
      expect(Kubereq, :list, fn _req -> {:ok, %{status: 403, body: %{}}} end)

      assert {:error, %Error{reason: :forbidden}} = Namespace.list(%{})
    end
  end

  describe "get/2" do
    test "returns the body on 200" do
      expect(Kubereq, :get, fn _req, name ->
        assert name == "fluxvale-app-1"
        {:ok, %{status: 200, body: %{"kind" => "Namespace"}}}
      end)

      assert {:ok, %{"kind" => "Namespace"}} = Namespace.get(%{}, "fluxvale-app-1")
    end

    test "404 is :not_found" do
      expect(Kubereq, :get, fn _req, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = Namespace.get(%{}, "missing")
    end
  end

  describe "create/3" do
    test "applies the manifest (cluster-scoped — no namespace arg)" do
      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        assert manifest["kind"] == "Namespace"
        assert manifest["metadata"]["name"] == "fluxvale-app-1"
        {:ok, %{status: 201, body: manifest}}
      end)

      assert {:ok, %{"kind" => "Namespace"}} = Namespace.create(%{}, "fluxvale-app-1", %{})
    end

    test "200 (identical apply) is still ok" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:ok, %{status: 200, body: :present}} end)

      assert {:ok, :present} = Namespace.create(%{}, "fluxvale-app-1", %{})
    end

    test "transport failure maps to a connection error" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:error, :transport_oops} end)

      assert {:error, %Error{reason: :connection_error}} = Namespace.create(%{}, "ns", %{})
    end
  end

  describe "delete/2" do
    test "202 accepts asynchronous deletion" do
      expect(Kubereq, :delete, fn _req, name ->
        assert name == "fluxvale-app-1"
        {:ok, %{status: 202}}
      end)

      assert :ok = Namespace.delete(%{}, "fluxvale-app-1")
    end

    test "404 is :not_found" do
      expect(Kubereq, :delete, fn _req, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = Namespace.delete(%{}, "missing")
    end
  end

  describe "exists?/2" do
    test "true when the namespace is readable" do
      expect(Kubereq, :get, fn _req, _name -> {:ok, %{status: 200, body: %{}}} end)

      assert {:ok, true} = Namespace.exists?(%{}, "fluxvale-app-1")
    end

    test "false on not_found — absence is a valid answer, not an error" do
      expect(Kubereq, :get, fn _req, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:ok, false} = Namespace.exists?(%{}, "missing")
    end

    test "errors other than not_found propagate" do
      expect(Kubereq, :get, fn _req, _name -> {:error, :transport_oops} end)

      assert {:error, %Error{reason: :connection_error}} = Namespace.exists?(%{}, "any")
    end
  end

  describe "status/2" do
    test "reads the phase from status" do
      body = %{"status" => %{"phase" => "Active"}}
      expect(Kubereq, :get, fn _req, _name -> {:ok, %{status: 200, body: body}} end)

      assert {:ok, "Active"} = Namespace.status(%{}, "fluxvale-app-1")
    end

    test "missing status block reads as nil" do
      expect(Kubereq, :get, fn _req, _name ->
        {:ok, %{status: 200, body: %{"kind" => "Namespace"}}}
      end)

      assert {:ok, nil} = Namespace.status(%{}, "fluxvale-app-1")
    end
  end

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

  test "attaches the request with the right api_version/kind (routing pin)" do
    expect(Kubereq, :attach, fn _req, opts ->
      assert opts[:api_version] == "v1"
      assert opts[:kind] == "Namespace"
      :pinned_req
    end)

    stub(Kubereq, :get, fn _req, _name -> {:ok, %{status: 404, body: %{}}} end)
    Namespace.get(%{}, "x")
  end
end
