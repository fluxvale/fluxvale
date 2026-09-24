defmodule FluxVale.Clients.K8s.Resources.SecretTest do
  use ExUnit.Case, async: true
  use Mimic

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Secret

  describe "build_manifest/3" do
    test "base64-encodes plain data values (kubereq does not)" do
      manifest = Secret.build_manifest("ns", "app-env", %{"API_KEY" => "s3cr3t"})

      assert manifest["kind"] == "Secret"
      assert manifest["type"] == "Opaque"
      assert manifest["data"] == %{"API_KEY" => Base.encode64("s3cr3t")}
    end
  end

  describe "decode_data/1" do
    test "decodes base64 values — the get_data payload path" do
      encoded = %{"API_KEY" => Base.encode64("s3cr3t")}

      assert Secret.decode_data(encoded) == {:ok, %{"API_KEY" => "s3cr3t"}}
    end

    test "errors on invalid base64" do
      assert {:error, %Error{reason: :validation_error, message: msg}} =
               Secret.decode_data(%{"BAD" => "not-base64!!"})

      assert msg =~ "BAD"
    end
  end

  describe "create/4" do
    test "applies the base64-encoded manifest" do
      expect(Kubereq, :apply, fn _req, manifest, field_manager ->
        assert manifest["kind"] == "Secret"
        assert manifest["data"]["TOKEN"] == Base.encode64("s3cr3t")
        assert field_manager == "fluxvale"
        {:ok, %{status: 201, body: manifest}}
      end)

      assert {:ok, %{"kind" => "Secret"}} =
               Secret.create(%{}, "ns", "app-env", %{"TOKEN" => "s3cr3t"})
    end

    test "200 (rotate apply) is still ok" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:ok, %{status: 200, body: :rotated}} end)

      assert {:ok, :rotated} = Secret.create(%{}, "ns", "app-env", %{"TOKEN" => "new"})
    end
  end

  describe "get_data/3" do
    test "returns decoded values" do
      body = %{"data" => %{"TOKEN" => Base.encode64("s3cr3t")}}
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 200, body: body}} end)

      assert {:ok, %{"TOKEN" => "s3cr3t"}} = Secret.get_data(%{}, "ns", "app-env")
    end

    test "a body without data decodes to an empty map" do
      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: %{"kind" => "Secret"}}}
      end)

      assert {:ok, data} = Secret.get_data(%{}, "ns", "app-env")
      assert data == %{}
    end

    test "get errors propagate undecoded" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = Secret.get_data(%{}, "ns", "missing")
    end
  end

  describe "exists?/3" do
    test "true when the secret is readable" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 200, body: %{}}} end)

      assert {:ok, true} = Secret.exists?(%{}, "ns", "app-env")
    end

    test "false on not_found — absence is a valid answer, not an error" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:ok, false} = Secret.exists?(%{}, "ns", "missing")
    end

    test "errors other than not_found propagate" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:error, :transport_oops} end)

      assert {:error, %Error{reason: :connection_error}} = Secret.exists?(%{}, "ns", "any")
    end
  end

  describe "delete/3" do
    test "200 deletes synchronously" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 200}} end)

      assert :ok = Secret.delete(%{}, "ns", "app-env")
    end

    test "202 accepts asynchronous deletion" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 202}} end)

      assert :ok = Secret.delete(%{}, "ns", "app-env")
    end

    test "404 is :not_found" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = Secret.delete(%{}, "ns", "missing")
    end
  end

  describe "upsert/4" do
    test "delegates to create (SSA idempotence)" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:ok, %{status: 201, body: :created}} end)

      assert {:ok, :created} = Secret.upsert(%{}, "ns", "app-env", %{"A" => "b"})
    end
  end

  test "attaches the request with the right api_version/kind (routing pin)" do
    expect(Kubereq, :attach, fn _req, opts ->
      assert opts[:api_version] == "v1"
      assert opts[:kind] == "Secret"
      :pinned_req
    end)

    stub(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)
    Secret.get(%{}, "ns", "x")
  end
end
