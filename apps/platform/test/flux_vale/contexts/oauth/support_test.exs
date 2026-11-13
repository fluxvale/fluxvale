defmodule FluxVale.OAuth.SupportTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias FluxVale.OAuth.Client.RedirectUris
  alias FluxVale.OAuth.PKCE
  alias FluxVale.OAuth.Resources

  describe "Resources" do
    test "an empty configured list falls back to the default" do
      with_mcp_oauth([resource_urls: []], fn ->
        assert Resources.configured() == ["https://mcp.fluxvale.com/mcp"]
        assert Resources.default() == "https://mcp.fluxvale.com/mcp"
        assert Resources.valid?("https://mcp.fluxvale.com/mcp")
      end)
    end

    test "blank entries are ignored and the first entry is the default" do
      with_mcp_oauth([resource_urls: ["", "https://mcp.example/mcp", nil]], fn ->
        assert Resources.configured() == ["https://mcp.example/mcp"]
        assert Resources.default() == "https://mcp.example/mcp"
      end)
    end

    test "a non-string resource is not valid" do
      refute Resources.valid?(nil)
      refute Resources.valid?(123)
      refute Resources.valid?("https://elsewhere.example/mcp")
    end
  end

  describe "PKCE" do
    test "a valid S256 verifier matches its challenge" do
      random = :crypto.strong_rand_bytes(32)
      verifier = Base.url_encode64(random, padding: false)
      digest = :crypto.hash(:sha256, verifier)
      challenge = Base.url_encode64(digest, padding: false)

      assert PKCE.valid_challenge?(challenge, "S256")
      assert PKCE.verify(verifier, challenge)
    end

    test "a plain method, a non-challenge, and a non-verifier are refused" do
      random = :crypto.strong_rand_bytes(32)
      verifier = Base.url_encode64(random, padding: false)
      digest = :crypto.hash(:sha256, verifier)
      challenge = Base.url_encode64(digest, padding: false)

      refute PKCE.valid_challenge?(challenge, "plain")
      refute PKCE.valid_challenge?("short", "S256")
      refute PKCE.valid_challenge?(nil, "S256")
      refute PKCE.verify(nil, challenge)
      refute PKCE.verify(verifier, nil)
      refute PKCE.verify("short", challenge)
    end
  end

  describe "RedirectUris" do
    test "empty, too many, and non-string entries are refused" do
      assert {:error, field: :redirect_uris, message: "at least one redirect URI is required"} =
               validate([])

      uris = for n <- 1..6, do: "https://client.example/cb#{n}"

      assert {:error, field: :redirect_uris, message: "at most five redirect URIs are allowed"} =
               validate(uris)

      assert {:error, field: :redirect_uris, message: message} = validate([:not_a_string])
      assert message =~ "unsupported redirect URI"
    end

    test "scheme-less, fragment, userinfo, and raw-control URIs are invalid" do
      refute RedirectUris.valid?("not a uri")
      refute RedirectUris.valid?("notauri")
      refute RedirectUris.valid?("https://client.example/cb\r\nX-Evil: 1")
      refute RedirectUris.valid?("https://client.example/cb with space")
      refute RedirectUris.valid?("https://client.example/cb\x00")
      refute RedirectUris.valid?("https://client.example/cb#frag")
      refute RedirectUris.valid?("https://user:pass@client.example/cb")
      refute RedirectUris.valid?(nil)
    end

    test "a custom scheme without an authority is accepted" do
      assert RedirectUris.valid?("claude:callback")
      assert RedirectUris.valid?("cursor://oauth/callback")
    end

    test "the custom-scheme list is runtime-configurable" do
      with_mcp_oauth([custom_schemes: ["myapp"]], fn ->
        assert RedirectUris.valid?("myapp://oauth/callback")
        refute RedirectUris.valid?("claude://oauth/callback")
      end)
    end
  end

  defp validate(uris) do
    changeset = %{Ash.Changeset.new(FluxVale.OAuth.Client) | attributes: %{redirect_uris: uris}}
    RedirectUris.validate(changeset, [], %{})
  end

  defp with_mcp_oauth(overrides, fun) do
    previous = Application.get_env(:flux_vale, :mcp_oauth)
    updated = Keyword.merge(previous || [], overrides)
    Application.put_env(:flux_vale, :mcp_oauth, updated)
    on_exit(fn -> restore(previous) end)
    fun.()
  end

  defp restore(nil), do: Application.delete_env(:flux_vale, :mcp_oauth)
  defp restore(value), do: Application.put_env(:flux_vale, :mcp_oauth, value)
end
