defmodule FluxValeWeb.OAuth.AuthorizationController do
  @moduledoc """
  The authorization endpoint and its consent screen (#766).

  `GET /oauth/authorize` validates the client, exact redirect URI,
  response type, PKCE S256, scopes, and resource BEFORE it asks for a
  session — an unknown client never becomes an open redirect. A signed
  out visitor is sent to `/sign-in` with the full authorize URL as
  `return_to`.

  The consent decision is a POST carrying a short-lived signed token
  that binds the whole request (client, redirect, scopes, resource,
  challenge, state, and the signed-in user), so a replayed or altered
  form cannot authorize a different request. Deny redirects with
  `error=access_denied`; approve mints the 60-second single-use code.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Api.Scopes
  alias FluxVale.OAuth
  alias FluxVale.OAuth.Client
  alias FluxValeWeb.OAuth.Issuer
  alias FluxValeWeb.Plugs.OAuthRateLimit
  alias FluxValeWeb.UserAuth

  @consent_salt "oauth consent"
  @consent_ttl 10 * 60

  @spec authorize(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def authorize(conn, params) do
    case rate_limit(conn, :authorize) do
      :ok ->
        case OAuth.validate_authorize_request(params) do
          {:ok, request} -> authorize_request(conn, request)
          {:error, error} -> authorization_error(conn, error)
        end

      {:error, retry_after} ->
        throttled(conn, retry_after)
    end
  end

  @spec consent(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def consent(conn, params) do
    case rate_limit(conn, :authorize) do
      :ok -> decide(conn, params)
      {:error, retry_after} -> throttled(conn, retry_after)
    end
  end

  defp authorize_request(conn, request) do
    session = get_session(conn)

    case UserAuth.resolve_user(session) do
      nil -> redirect_to_sign_in(conn)
      user -> render_consent(conn, request, user)
    end
  end

  defp render_consent(conn, request, user) do
    payload = %{
      user_id: user.id,
      client_id: request.client.client_id,
      redirect_uri: request.redirect_uri,
      scopes: request.scopes,
      resource: request.resource,
      resource_defaulted: request.resource_defaulted,
      code_challenge: request.code_challenge,
      state: request.state
    }

    consent_token =
      Phoenix.Token.sign(FluxValeWeb.Endpoint, @consent_salt, payload)

    conn = assign(conn, :flash, conn.assigns[:flash] || %{})

    conn
    |> put_view(FluxValeWeb.OAuthHTML)
    |> render(:authorize, %{
      page_title: "Authorize #{request.client.client_name} — FluxVale",
      client_name: request.client.client_name,
      signed_in_as: user.username,
      redirect_authority: redirect_authority(request.redirect_uri),
      scopes: Enum.map(request.scopes, &%{name: &1, description: Scopes.describe(&1)}),
      consent_token: consent_token
    })
  end

  defp decide(conn, params) do
    case verify_consent(params["consent_token"]) do
      {:ok, payload} ->
        decide_verified(conn, payload, params["decision"])

      {:error, _reason} ->
        error_page(
          conn,
          400,
          "This consent request expired",
          "Start the connection again from your MCP client."
        )
    end
  end

  defp verify_consent(token) when is_binary(token) do
    Phoenix.Token.verify(FluxValeWeb.Endpoint, @consent_salt, token, max_age: @consent_ttl)
  end

  defp verify_consent(_token), do: {:error, :missing}

  defp decide_verified(conn, payload, decision) when decision in ["approve", "deny"] do
    expected_user_id = payload[:user_id]

    session = get_session(conn)

    case UserAuth.resolve_user(session) do
      %{id: ^expected_user_id} = user ->
        finish_decision(conn, payload, user, decision)

      _signed_out_or_other_user ->
        error_page(
          conn,
          400,
          "Your session changed",
          "Sign in again and restart the connection from your MCP client."
        )
    end
  end

  defp decide_verified(conn, _payload, _decision) do
    error_page(conn, 400, "Choose allow or deny", "The consent decision was not recognized.")
  end

  defp finish_decision(conn, payload, user, "deny") do
    client = fetch_client(payload[:client_id])

    OAuth.record_audit_event(%{
      kind: :authorize_denied,
      oauth_client_id: client && client.id,
      actor_id: user.id,
      resource: payload[:resource],
      metadata: %{"resource_defaulted" => payload[:resource_defaulted]}
    })

    redirect_with_params(conn, payload[:redirect_uri], %{
      "error" => "access_denied",
      "error_description" => "the user denied the authorization request",
      "state" => payload[:state],
      "iss" => Issuer.issuer()
    })
  end

  defp finish_decision(conn, payload, user, "approve") do
    case fetch_client(payload[:client_id]) do
      nil ->
        error_page(
          conn,
          400,
          "The client is no longer registered",
          "Start the connection again from your MCP client."
        )

      client ->
        request = %{
          client: client,
          user: user,
          redirect_uri: payload[:redirect_uri],
          scopes: payload[:scopes],
          resource: payload[:resource],
          resource_defaulted: payload[:resource_defaulted],
          code_challenge: payload[:code_challenge]
        }

        case OAuth.issue_authorization_code(request) do
          {:ok, issued} ->
            redirect_with_params(conn, payload[:redirect_uri], %{
              "code" => issued.code,
              "state" => payload[:state],
              "iss" => Issuer.issuer()
            })

          # coveralls-ignore-start - DB outage on an already-validated
          # consent; the page answers the retry arm.
          {:error, _refused} ->
            error_page(
              conn,
              500,
              "The authorization code could not be issued",
              "Try again from your MCP client."
            )

            # coveralls-ignore-stop
        end
    end
  end

  defp fetch_client(client_id) when is_binary(client_id) do
    case Client.get_by_client_id(client_id, authorize?: false) do
      {:ok, client} -> client
      {:error, _not_found} -> nil
    end
  end

  defp fetch_client(_client_id), do: nil

  defp authorization_error(conn, %{redirect?: true} = error) do
    redirect_with_params(conn, error.redirect_uri, %{
      "error" => to_string(error.error),
      "error_description" => error.description,
      "state" => error[:state],
      "iss" => Issuer.issuer()
    })
  end

  defp authorization_error(conn, error) do
    error_page(conn, 400, "This authorization request can't be completed", error.description)
  end

  defp redirect_to_sign_in(conn) do
    # coveralls-ignore-start - a valid authorize request always has
    # query parameters; the empty arm only guards a hand-built conn.
    return_to =
      case conn.query_string do
        "" -> conn.request_path
        query -> conn.request_path <> "?" <> query
      end

    # coveralls-ignore-stop

    redirect(conn, to: "/sign-in?return_to=" <> URI.encode_www_form(return_to))
  end

  # Custom-scheme redirects (claude://, cursor://) are not something
  # Phoenix.Controller.redirect/2 accepts as an external URL, so the
  # Location header is written directly — the exact-match validation
  # already happened.
  defp redirect_with_params(conn, redirect_uri, params) do
    separator = if String.contains?(redirect_uri, "?"), do: "&", else: "?"

    query =
      params
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> URI.encode_query()

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("location", redirect_uri <> separator <> query)
    |> send_resp(302, "")
  end

  defp redirect_authority(redirect_uri) do
    case URI.parse(redirect_uri).authority do
      nil -> redirect_uri
      authority -> authority
    end
  end

  defp rate_limit(conn, bucket) do
    case OAuthRateLimit.allow?(conn, bucket) do
      :ok -> :ok
      {:error, retry_after} -> {:error, retry_after}
    end
  end

  defp throttled(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> error_page(
      429,
      "Too many authorization attempts",
      "Wait a moment, then start the connection again from your MCP client."
    )
  end

  defp error_page(conn, status, title, detail) do
    conn
    |> assign(:flash, conn.assigns[:flash] || %{})
    |> put_status(status)
    |> put_view(FluxValeWeb.OAuthHTML)
    |> render(:error, %{page_title: title <> " — FluxVale", title: title, detail: detail})
  end
end
