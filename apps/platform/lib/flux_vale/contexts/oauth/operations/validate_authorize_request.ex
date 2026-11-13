defmodule FluxVale.OAuth.Operations.ValidateAuthorizeRequest do
  @moduledoc """
  The authorization request's validation (#766): client, exact
  redirect URI, response type, PKCE S256, scopes, resource, state.

  Validation order is the security order: the client and redirect URI
  are established before any error is sent anywhere, so an unknown
  client never becomes an open redirect. Errors after that point carry
  the validated redirect target and the state back to the client.

  The resource parameter is optional for compatibility (older MCP
  clients predate RFC 8707): when absent the request binds to the
  configured default and marks `resource_defaulted` for the audit row.
  A present value must match exactly.
  """

  alias FluxVale.Api.Scopes
  alias FluxVale.OAuth.Client
  alias FluxVale.OAuth.PKCE
  alias FluxVale.OAuth.Resources

  @max_state_length 512

  @doc """
  Returns `{:ok, request}` where `request` is a map with `:client`,
  `:redirect_uri`, `:scopes`, `:resource`, `:resource_defaulted`,
  `:code_challenge`, and `:state`.

  Errors are `{:error, error}` where `error` is a map:
  `%{error: atom, description: String.t(), redirect?: boolean,
  redirect_uri: String.t() | nil, state: String.t() | nil,
  client: Client.t() | nil}`.
  """
  @spec call(map()) :: {:ok, map()} | {:error, map()}
  def call(params) when is_map(params) do
    client_id = param(params, :client_id)
    redirect_uri = param(params, :redirect_uri)
    state = param(params, :state)

    with {:ok, client} <- fetch_client(client_id),
         {:ok, redirect_uri} <- redirect_uri(client, redirect_uri) do
      validate_rest(client, redirect_uri, state, params)
    else
      {:error, error} -> {:error, Map.merge(%{redirect?: false, state: state}, error)}
    end
  end

  def call(_params), do: {:error, error(:invalid_request, "malformed request", false, nil, nil)}

  defp fetch_client(client_id) when is_binary(client_id) and client_id != "" do
    case Client.get_by_client_id(client_id, authorize?: false) do
      {:ok, client} -> {:ok, client}
      {:error, _not_found} -> {:error, error(:invalid_request, "unknown client", false, nil, nil)}
    end
  end

  defp fetch_client(_client_id),
    do: {:error, error(:invalid_request, "client_id is required", false, nil, nil)}

  defp redirect_uri(client, redirect_uri) when is_binary(redirect_uri) do
    if redirect_uri in client.redirect_uris do
      {:ok, redirect_uri}
    else
      {:error,
       error(:invalid_request, "redirect_uri is not registered for this client", false, nil, nil)}
    end
  end

  defp redirect_uri(_client, _redirect_uri),
    do: {:error, error(:invalid_request, "redirect_uri is required", false, nil, nil)}

  defp validate_rest(client, redirect_uri, state, params) do
    with :ok <- response_type(param(params, :response_type)),
         :ok <- validate_state(state),
         :ok <- pkce(param(params, :code_challenge), param(params, :code_challenge_method)),
         {:ok, scopes} <- scopes(param(params, :scope)),
         {:ok, resource, defaulted?} <- resource(param(params, :resource)) do
      {:ok,
       %{
         client: client,
         redirect_uri: redirect_uri,
         scopes: scopes,
         resource: resource,
         resource_defaulted: defaulted?,
         code_challenge: param(params, :code_challenge),
         state: state
       }}
    else
      {:error, error} ->
        {:error,
         Map.merge(
           %{redirect?: true, redirect_uri: redirect_uri, state: state, client: client},
           error
         )}
    end
  end

  defp response_type("code"), do: :ok

  defp response_type(_other),
    do: {:error, error(:unsupported_response_type, "response_type must be code", true, nil, nil)}

  defp validate_state(nil), do: :ok

  defp validate_state(state) when is_binary(state) and byte_size(state) <= @max_state_length,
    do: :ok

  defp validate_state(_state),
    do: {:error, error(:invalid_request, "state is too long", true, nil, nil)}

  defp pkce(challenge, "S256") do
    if PKCE.valid_challenge?(challenge, "S256") do
      :ok
    else
      {:error, error(:invalid_request, "a valid S256 code_challenge is required", true, nil, nil)}
    end
  end

  defp pkce(_challenge, _method),
    do: {:error, error(:invalid_request, "PKCE with S256 is required", true, nil, nil)}

  defp scopes(nil), do: {:ok, []}

  defp scopes(scope) when is_binary(scope) do
    scopes =
      scope
      |> String.split()
      |> Enum.reject(&(&1 == ""))

    case Scopes.validate_oauth(scopes) do
      :ok ->
        {:ok, Scopes.strip_oauth(scopes)}

      {:error, {_kind, invalid}} ->
        {:error, error(:invalid_scope, "scope #{invalid} is not supported", true, nil, nil)}
    end
  end

  defp scopes(scope) when is_list(scope) do
    case Scopes.validate_oauth(scope) do
      :ok ->
        {:ok, Scopes.strip_oauth(scope)}

      {:error, {_kind, invalid}} ->
        {:error, error(:invalid_scope, "scope #{invalid} is not supported", true, nil, nil)}
    end
  end

  defp scopes(_scope),
    do: {:error, error(:invalid_scope, "scope must be a space-delimited string", true, nil, nil)}

  defp resource(nil), do: {:ok, Resources.default(), true}

  defp resource(resource) when is_binary(resource) do
    if Resources.valid?(resource) do
      {:ok, resource, false}
    else
      {:error,
       error(
         :invalid_target,
         "resource is not served by this authorization server",
         true,
         nil,
         nil
       )}
    end
  end

  defp resource(_resource),
    do: {:error, error(:invalid_target, "resource must be a URI", true, nil, nil)}

  defp error(kind, description, redirect?, redirect_uri, _state) do
    %{
      error: kind,
      description: description,
      redirect?: redirect?,
      redirect_uri: redirect_uri
    }
  end

  defp param(params, key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
