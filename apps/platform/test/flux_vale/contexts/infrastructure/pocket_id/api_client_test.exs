defmodule FluxVale.Infrastructure.PocketId.ApiClientTest do
  @moduledoc """
  The PocketID API client's wire contract (#597 §4.3, pinned against
  the shipped image v2.19.2's live transcript): X-API-KEY auth on the
  instance's own base URL, the admin-key verification probe
  (`GET /api/oidc/clients`), the key-family listing for expiry
  correlation, and the 401/403/unreachable split that never folds.
  HTTP is Mimic-stubbed — the Tailscale ApiClient stance.
  """

  use ExUnit.Case, async: true
  use Mimic

  alias FluxVale.Infrastructure.PocketId.ApiClient

  @base_url "https://pocketid.example"
  @key "test-key-not-a-real-credential"

  # Every request rides the X-API-KEY header on the caller's base URL
  # with the 3s probe budget and no retries — the contract every
  # function shares, pinned once here.
  defp expect_request(method, path, respond) do
    expect(Req, method, fn req, opts ->
      assert req.options[:base_url] == @base_url
      assert Req.Request.get_header(req, "x-api-key") == [@key]
      assert opts[:url] == path
      assert opts[:receive_timeout] == 3_000
      assert req.options[:retry] == false
      assert req.options[:connect_options][:timeout] == 3_000

      respond.(opts)
    end)
  end

  describe "verify_admin_key/2" do
    test "a 2xx is a working admin key" do
      expect_request(:get, "/api/oidc/clients", fn _opts ->
        {:ok, %Req.Response{status: 200, body: []}}
      end)

      assert :ok = ApiClient.verify_admin_key(@base_url, @key)
    end

    test "401 = rejected (expired and revoked present identically)" do
      expect_request(:get, "/api/oidc/clients", fn _opts ->
        {:ok, %Req.Response{status: 401, body: %{"error" => "unauthorized"}}}
      end)

      assert {:error, :unauthorized} = ApiClient.verify_admin_key(@base_url, @key)
    end

    test "403 = valid key without admin permission — a different failure, never folded" do
      expect_request(:get, "/api/oidc/clients", fn _opts ->
        {:ok, %Req.Response{status: 403, body: %{"error" => "api_key_auth_not_allowed"}}}
      end)

      assert {:error, :forbidden} = ApiClient.verify_admin_key(@base_url, @key)
    end

    test "any other status carries the status plus a bounded snippet" do
      expect_request(:get, "/api/oidc/clients", fn _opts ->
        {:ok, %Req.Response{status: 500, body: %{"error" => "boom"}}}
      end)

      assert {:error, %{status: 500, body: snippet}} = ApiClient.verify_admin_key(@base_url, @key)
      assert String.contains?(snippet, "boom")
    end

    test "a transport failure (down, waking, bad host) is :unreachable" do
      expect(Req, :get, fn _req, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, :unreachable} = ApiClient.verify_admin_key(@base_url, @key)
    end
  end

  describe "list_api_keys/2" do
    test "returns the key family (the bare-array envelope)" do
      expect_request(:get, "/api/api-keys", fn _opts ->
        {:ok, %Req.Response{status: 200, body: [%{"id" => "k1"}, %{"id" => "k2"}]}}
      end)

      assert {:ok, [%{"id" => "k1"}, %{"id" => "k2"}]} =
               ApiClient.list_api_keys(@base_url, @key)
    end

    test "accepts the object-wrapped envelope" do
      expect_request(:get, "/api/api-keys", fn _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"apiKey" => %{"data" => [%{"id" => "k1"}]}}
         }}
      end)

      assert {:ok, [%{"id" => "k1"}]} = ApiClient.list_api_keys(@base_url, @key)
    end

    # A shape nobody documented is unusable for correlation, not a
    # crash — the expiry nicety degrades to nil at the caller.
    test "an unrecognized body is an empty family, not an error" do
      expect_request(:get, "/api/api-keys", fn _opts ->
        {:ok, %Req.Response{status: 200, body: "nope"}}
      end)

      assert {:ok, []} = ApiClient.list_api_keys(@base_url, @key)
    end

    test "non-map entries are dropped" do
      expect_request(:get, "/api/api-keys", fn _opts ->
        {:ok, %Req.Response{status: 200, body: [%{"id" => "k1"}, "junk"]}}
      end)

      assert {:ok, [%{"id" => "k1"}]} = ApiClient.list_api_keys(@base_url, @key)
    end

    test "errors ride the same verdicts as the probe" do
      expect_request(:get, "/api/api-keys", fn _opts ->
        {:ok, %Req.Response{status: 401, body: nil}}
      end)

      assert {:error, :unauthorized} = ApiClient.list_api_keys(@base_url, @key)

      expect_request(:get, "/api/api-keys", fn _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      assert {:error, :unreachable} = ApiClient.list_api_keys(@base_url, @key)
    end
  end

  # #597 S4: the wiring's two calls — the issuer source and the
  # client mint. Discovery rides a KEYLESS request (the document is
  # public; the admin key would only widen its exposure); the mint
  # rides the keyed contract with the v2.19.2 camelCase wire shape.
  describe "get_discovery/1" do
    test "returns the issuer string VERBATIM from the document" do
      expect(Req, :get, fn req, opts ->
        assert req.options[:base_url] == @base_url
        # Keyless: the public document never sees the admin key.
        assert Req.Request.get_header(req, "x-api-key") == []
        assert opts[:url] == "/.well-known/openid-configuration"
        assert req.options[:retry] == false

        {:ok,
         %Req.Response{
           status: 200,
           body: %{"issuer" => "https://id.example", "token_endpoint" => "other"}
         }}
      end)

      assert {:ok, "https://id.example"} = ApiClient.get_discovery(@base_url)
    end

    test "a 2xx without an issuer string is :no_issuer — answered, but broken" do
      expect(Req, :get, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"token_endpoint" => "x"}}}
      end)

      assert {:error, :no_issuer} = ApiClient.get_discovery(@base_url)
    end

    test "a waking PocketID's 503 carries the status (the wake-race shape)" do
      expect(Req, :get, fn _req, _opts ->
        {:ok, %Req.Response{status: 503, body: "waking"}}
      end)

      assert {:error, %{status: 503, body: snippet}} = ApiClient.get_discovery(@base_url)
      assert String.contains?(snippet, "waking")
    end

    test "a transport failure is :unreachable" do
      expect(Req, :get, fn _req, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, :unreachable} = ApiClient.get_discovery(@base_url)
    end
  end

  describe "create_client/3" do
    @mint_attrs %{
      name: "FluxVale · My Vault",
      callback_url: "https://vw.example/signin",
      pkce: true
    }

    # The keyed contract plus the create's own wire shape.
    defp expect_mint(respond) do
      expect(Req, :post, fn req, opts ->
        assert req.options[:base_url] == @base_url
        assert Req.Request.get_header(req, "x-api-key") == [@key]
        assert opts[:url] == "/api/oidc/clients"

        assert opts[:json] == %{
                 "name" => "FluxVale · My Vault",
                 "callbackUrls" => ["https://vw.example/signin"],
                 "isPublic" => false,
                 "pkceEnabled" => true
               }

        respond.()
      end)
    end

    test "a 201 yields PocketID's ids and the one-time secret" do
      expect_mint(fn ->
        {:ok,
         %Req.Response{
           status: 201,
           body: %{
             "id" => "080258e5",
             "createdSecret" => %{"id" => "sec-1", "secret" => "3QRT4i5W"}
           }
         }}
      end)

      assert {:ok, client} = ApiClient.create_client(@base_url, @key, @mint_attrs)
      assert client.client_id == "080258e5"
      assert client.client_name == "FluxVale · My Vault"
      assert client.secret_id == "sec-1"
      assert client.secret == "3QRT4i5W"
    end

    test "a 2xx without a created secret is an honest refusal, not a secretless client" do
      expect_mint(fn -> {:ok, %Req.Response{status: 201, body: %{"id" => "080258e5"}}} end)

      assert {:error, :no_created_secret} =
               ApiClient.create_client(@base_url, @key, @mint_attrs)
    end

    test "a malformed created secret (empty value) is the same refusal" do
      expect_mint(fn ->
        {:ok,
         %Req.Response{
           status: 201,
           body: %{"id" => "c", "createdSecret" => %{"id" => "s", "secret" => ""}}
         }}
      end)

      assert {:error, :no_created_secret} =
               ApiClient.create_client(@base_url, @key, @mint_attrs)
    end

    test "401 at the mint is :unauthorized (the caller's key-rejected verdict)" do
      expect_mint(fn -> {:ok, %Req.Response{status: 401, body: nil}} end)

      assert {:error, :unauthorized} = ApiClient.create_client(@base_url, @key, @mint_attrs)
    end

    test "403 at the mint is :forbidden (never folded into 401)" do
      expect_mint(fn -> {:ok, %Req.Response{status: 403, body: nil}} end)

      assert {:error, :forbidden} = ApiClient.create_client(@base_url, @key, @mint_attrs)
    end

    test "a refused create (400) carries the status plus a bounded snippet" do
      expect_mint(fn ->
        {:ok, %Req.Response{status: 400, body: %{"error" => "name too long"}}}
      end)

      assert {:error, %{status: 400, body: snippet}} =
               ApiClient.create_client(@base_url, @key, @mint_attrs)

      assert String.contains?(snippet, "name too long")
    end

    test "a transport failure mid-mint is :unreachable — the wake race at the create leg" do
      expect_mint(fn -> {:error, %Req.TransportError{reason: :timeout}} end)

      assert {:error, :unreachable} = ApiClient.create_client(@base_url, @key, @mint_attrs)
    end
  end
end
