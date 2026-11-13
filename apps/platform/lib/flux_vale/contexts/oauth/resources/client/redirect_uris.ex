defmodule FluxVale.OAuth.Client.RedirectUris do
  @moduledoc """
  The registration redirect-URI allowlist (#766, OAuth 2.1 §2.3 +
  RFC 8252 §7.3): HTTPS anywhere, HTTP only on a loopback host, and
  the known desktop-client custom schemes.

  The exact-match rule at authorization time is the security boundary;
  this validation keeps obviously unsafe values out of the client
  registry in the first place. Fragments and userinfo are refused —
  both are invisible to the exact-match comparison in a way that
  invites confusion.
  """

  use Ash.Resource.Validation

  @loopback_hosts ~w(localhost 127.0.0.1 ::1 [::1])
  @default_custom_schemes ~w(claude cursor vscode codex)

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, _context) do
    uris = Ash.Changeset.get_attribute(changeset, :redirect_uris) || []

    cond do
      uris == [] ->
        {:error, field: :redirect_uris, message: "at least one redirect URI is required"}

      length(uris) > 5 ->
        {:error, field: :redirect_uris, message: "at most five redirect URIs are allowed"}

      invalid = Enum.find(uris, &(not valid?(normalize(&1)))) ->
        {:error, field: :redirect_uris, message: "unsupported redirect URI #{inspect(invalid)}"}

      true ->
        :ok
    end
  end

  defp normalize(uri) when is_binary(uri), do: String.trim(uri)
  defp normalize(uri), do: uri

  @doc "Is this an allowed redirect URI shape?"
  @spec valid?(term()) :: boolean()
  def valid?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: nil} ->
        false

      %URI{scheme: "https", host: host, userinfo: nil, fragment: nil} when is_binary(host) ->
        host != ""

      %URI{scheme: "http", host: host, userinfo: nil, fragment: nil} when is_binary(host) ->
        host in @loopback_hosts

      %URI{scheme: scheme, userinfo: nil, fragment: nil} ->
        scheme in custom_schemes()

      _other ->
        false
    end
  end

  def valid?(_uri), do: false

  @doc "The custom schemes registration accepts (runtime-configurable)."
  @spec custom_schemes() :: [String.t()]
  def custom_schemes do
    :flux_vale
    |> Application.get_env(:mcp_oauth, [])
    |> Keyword.get(:custom_schemes, @default_custom_schemes)
  end
end
