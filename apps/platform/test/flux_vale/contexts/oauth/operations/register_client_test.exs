defmodule FluxVale.OAuth.Operations.RegisterClientTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.OAuth
  alias FluxVale.OAuth.AuditEvent

  describe "call/2" do
    test "registers a public client with the RFC 7591 defaults and audits it" do
      {:ok, client} =
        OAuth.register_client(%{
          "client_name" => "Claude Code",
          "redirect_uris" => ["http://127.0.0.1:53682/callback"],
          "scope" => "instances:read offline_access"
        })

      assert client.client_id =~ ~r/^fvoc_[A-Za-z0-9_-]{43}$/
      assert client.client_name == "Claude Code"
      assert client.redirect_uris == ["http://127.0.0.1:53682/callback"]
      assert client.grant_types == ["authorization_code", "refresh_token"]
      assert client.response_types == ["code"]
      assert client.token_endpoint_auth_method == "none"

      assert [audit] = Enum.filter(audit_rows(), &(&1.oauth_client_id == client.id))
      assert audit.kind == :client_registered
    end

    test "https redirects are accepted anywhere" do
      {:ok, client} =
        OAuth.register_client(%{
          "redirect_uris" => ["https://client.example/oauth/callback"]
        })

      assert client.redirect_uris == ["https://client.example/oauth/callback"]
    end

    test "http is accepted only on loopback hosts" do
      assert {:ok, _client} =
               OAuth.register_client(%{
                 "redirect_uris" => ["http://localhost:3000/callback"]
               })

      assert {:error, {:invalid_redirect_uri, "http://client.example/callback"}} =
               OAuth.register_client(%{
                 "redirect_uris" => ["http://client.example/callback"]
               })
    end

    test "known custom schemes are accepted; unknown and dangerous ones are not" do
      assert {:ok, _client} =
               OAuth.register_client(%{"redirect_uris" => ["claude://oauth/callback"]})

      assert {:error, {:invalid_redirect_uri, "myapp://oauth/callback"}} =
               OAuth.register_client(%{"redirect_uris" => ["myapp://oauth/callback"]})

      assert {:error, {:invalid_redirect_uri, "javascript:alert(1)"}} =
               OAuth.register_client(%{"redirect_uris" => ["javascript:alert(1)"]})
    end

    test "fragments and userinfo are refused" do
      assert {:error, {:invalid_redirect_uri, "https://client.example/cb#frag"}} =
               OAuth.register_client(%{
                 "redirect_uris" => ["https://client.example/cb#frag"]
               })

      assert {:error, {:invalid_redirect_uri, "https://user:pass@client.example/cb"}} =
               OAuth.register_client(%{
                 "redirect_uris" => ["https://user:pass@client.example/cb"]
               })
    end

    test "client names are escaped, trimmed, and capped" do
      {:ok, client} =
        OAuth.register_client(%{
          "client_name" => "  <script>alert(1)</script>\n" <> String.duplicate("x", 200),
          "redirect_uris" => ["https://client.example/cb"]
        })

      assert client.client_name =~ "<script>alert(1)</script>"
      refute client.client_name =~ "\n"
      assert String.length(client.client_name) == 100
    end

    test "a missing name defaults to the generic label" do
      {:ok, client} = OAuth.register_client(%{"redirect_uris" => ["https://client.example/cb"]})
      assert client.client_name == "MCP client"
    end

    test "unknown grant types, response types, and auth methods are refused" do
      assert {:error, {:invalid_client_metadata, "unsupported grant type"}} =
               OAuth.register_client(%{
                 "redirect_uris" => ["https://client.example/cb"],
                 "grant_types" => ["client_credentials"]
               })

      assert {:error, {:invalid_client_metadata, ~s(response_types must be [\"code\"])}} =
               OAuth.register_client(%{
                 "redirect_uris" => ["https://client.example/cb"],
                 "response_types" => ["token"]
               })

      assert {:error, {:invalid_client_metadata, "only public clients are supported"}} =
               OAuth.register_client(%{
                 "redirect_uris" => ["https://client.example/cb"],
                 "token_endpoint_auth_method" => "client_secret_basic"
               })
    end

    test "unknown and duplicate scopes are refused; offline_access is a no-op" do
      assert {:error, {:invalid_scope, "admin"}} =
               OAuth.register_client(%{
                 "redirect_uris" => ["https://client.example/cb"],
                 "scope" => "instances:read admin"
               })

      assert {:error, {:duplicate_scope, "instances:read"}} =
               OAuth.register_client(%{
                 "redirect_uris" => ["https://client.example/cb"],
                 "scope" => "instances:read instances:read"
               })
    end

    test "an empty redirect list is refused" do
      assert {:error, {:invalid_client_metadata, "redirect_uris must be a non-empty array"}} =
               OAuth.register_client(%{"redirect_uris" => []})
    end
  end

  defp audit_rows do
    cutoff = DateTime.add(DateTime.utc_now(), 60, :second)
    query = Ash.Query.for_read(AuditEvent, :stale, %{cutoff: cutoff})
    Ash.read!(query, authorize?: false)
  end
end
