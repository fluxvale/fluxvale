defmodule FluxVale.TestSupport.OIDC.ProviderPlug do
  @moduledoc false

  # The HTTP face of FluxVale.TestSupport.OIDC.Provider: Bandit hands
  # it the provider pid in its opts ([provider: pid] — set in the
  # provider's init), and every endpoint forwards to the GenServer
  # that owns the state. See the provider's moduledoc for the endpoint
  # contracts.

  import Plug.Conn

  alias FluxVale.TestSupport.OIDC.Provider

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET", path_info: [".well-known", "openid-configuration"]} = conn,
        provider: provider
      ) do
    send_json(conn, 200, Provider.discovery(provider))
  end

  def call(%Plug.Conn{method: "GET", path_info: ["authorize"]} = conn, provider: provider) do
    params = URI.decode_query(conn.query_string)

    case Provider.authorize(provider, params) do
      {:ok, %{code: code, redirect_uri: redirect_uri, state: state}} ->
        query =
          %{code: code, state: state}
          |> URI.encode_query()

        conn
        |> put_resp_header("location", redirect_uri <> "?" <> query)
        |> send_resp(302, "")

      {:error, description} ->
        send_json(conn, 400, %{"error" => "invalid_request", "error_description" => description})
    end
  end

  def call(%Plug.Conn{method: "POST", path_info: ["token"]} = conn, provider: provider) do
    {:ok, body, conn} = read_body(conn)
    params = URI.decode_query(body)

    case Provider.token(provider, params, basic_credentials(conn)) do
      {:ok, token} ->
        send_json(conn, 200, token)

      {:error, status, error, description} ->
        send_json(conn, status, %{"error" => error, "error_description" => description})
    end
  end

  def call(%Plug.Conn{method: "GET", path_info: ["jwks.json"]} = conn, provider: provider) do
    send_json(conn, 200, Provider.jwks(provider))
  end

  def call(conn, _opts), do: send_json(conn, 404, %{"error" => "not_found"})

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  # assent's default client authentication is client_secret_basic —
  # "Basic " <> base64(client_id:client_secret) (oauth2.ex).
  defp basic_credentials(conn) do
    case get_req_header(conn, "authorization") do
      ["Basic " <> encoded] -> decode_basic(encoded)
      _no_basic_header -> nil
    end
  end

  defp decode_basic(encoded) do
    with {:ok, decoded} <- Base.decode64(encoded),
         [id, secret] <- String.split(decoded, ":", parts: 2) do
      {id, secret}
    else
      _malformed -> nil
    end
  end
end
