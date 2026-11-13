defmodule FluxVale.OAuth.Operations.RegisterClient do
  @moduledoc """
  Dynamic client registration (#766, RFC 7591) — public clients only.

  The endpoint is unauthenticated by design (a fresh MCP client has no
  credential yet); the gates are the redirect-URI allowlist, the
  grant/response-type set, and the catalog scope validation. The
  controller owns the rate limit and the per-window client cap; this
  operation owns the metadata rules.
  """

  alias FluxVale.Api.Scopes
  alias FluxVale.OAuth.Client
  alias FluxVale.OAuth.Client.RedirectUris

  @allowed_grant_types ["authorization_code", "refresh_token"]
  @allowed_response_types ["code"]
  @max_name_length 100

  @doc """
  Registers a client from RFC 7591 metadata.

  Returns `{:ok, %Client{}}` or one of:

  * `{:error, {:invalid_client_metadata, detail}}`
  * `{:error, {:invalid_redirect_uri, uri}}`
  * `{:error, {:invalid_scope, scope}}` / `{:error, {:duplicate_scope, scope}}`
  * `{:error, changeset}` — the resource-level backstop refused
  """
  @spec call(map(), keyword()) :: {:ok, Client.t()} | {:error, term()}
  def call(params, opts \\ []) do
    opts = Keyword.put_new(opts, :authorize?, false)

    with {:ok, redirect_uris} <- redirect_uris(params),
         :ok <- validate_redirect_uris(redirect_uris),
         {:ok, grant_types} <- grant_types(params),
         {:ok, response_types} <- response_types(params),
         :ok <- token_endpoint_auth_method(params),
         :ok <- validate_scope(param(params, :scope)) do
      client_id = "fvoc_" <> random()

      attrs = %{
        client_id: client_id,
        client_name: client_name(param(params, :client_name)),
        redirect_uris: redirect_uris,
        grant_types: grant_types,
        response_types: response_types,
        token_endpoint_auth_method: "none"
      }

      changeset = Ash.Changeset.for_create(Client, :register, attrs, opts)

      case Ash.create(changeset) do
        {:ok, client} ->
          FluxVale.OAuth.record_audit_event(%{
            kind: :client_registered,
            oauth_client_id: client.id,
            metadata: %{"redirect_uris" => redirect_uris}
          })

          {:ok, client}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp redirect_uris(params) do
    case param(params, :redirect_uris) do
      uris when is_list(uris) and uris != [] ->
        if Enum.all?(uris, &is_binary/1) do
          {:ok, Enum.map(uris, &String.trim/1)}
        else
          {:error, {:invalid_client_metadata, "redirect_uris must be strings"}}
        end

      _other ->
        {:error, {:invalid_client_metadata, "redirect_uris must be a non-empty array"}}
    end
  end

  defp validate_redirect_uris(uris) do
    case Enum.find(uris, &(not RedirectUris.valid?(&1))) do
      nil -> :ok
      invalid -> {:error, {:invalid_redirect_uri, invalid}}
    end
  end

  defp grant_types(params) do
    case param(params, :grant_types) do
      nil ->
        {:ok, @allowed_grant_types}

      types when is_list(types) ->
        if Enum.all?(types, &(&1 in @allowed_grant_types)) do
          {:ok, Enum.uniq(types)}
        else
          {:error, {:invalid_client_metadata, "unsupported grant type"}}
        end

      _other ->
        {:error, {:invalid_client_metadata, "grant_types must be an array"}}
    end
  end

  defp response_types(params) do
    case param(params, :response_types) do
      nil ->
        {:ok, @allowed_response_types}

      types ->
        if types == @allowed_response_types do
          {:ok, types}
        else
          {:error, {:invalid_client_metadata, "response_types must be [\"code\"]"}}
        end
    end
  end

  defp token_endpoint_auth_method(params) do
    case param(params, :token_endpoint_auth_method) do
      nil -> :ok
      "none" -> :ok
      _other -> {:error, {:invalid_client_metadata, "only public clients are supported"}}
    end
  end

  defp validate_scope(nil), do: :ok

  defp validate_scope(scope) when is_binary(scope) do
    scopes =
      scope
      |> String.split()
      |> Enum.reject(&(&1 == ""))

    Scopes.validate_oauth(scopes)
  end

  defp validate_scope(_scope),
    do: {:error, {:invalid_client_metadata, "scope must be a space-delimited string"}}

  defp client_name(nil), do: "MCP client"

  defp client_name(name) when is_binary(name) do
    cleaned =
      name
      |> String.replace(~r/[\x00-\x1F\x7F]/, "")
      |> String.trim()
      |> String.codepoints()
      |> Enum.take(@max_name_length)
      |> Enum.join()

    case cleaned do
      "" -> "MCP client"
      trimmed -> trimmed
    end
  end

  defp client_name(_name), do: "MCP client"

  defp random do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp param(params, key) when is_map(params) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp param(_params, _key), do: nil
end
