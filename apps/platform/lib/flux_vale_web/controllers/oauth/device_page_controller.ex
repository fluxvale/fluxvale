defmodule FluxValeWeb.OAuth.DevicePageController do
  @moduledoc """
  The hosted verification and consent page for the OAuth device grant
  (#886, RFC 8628 §3.3).

  `GET /oauth/device` requires a signed-in session (sending anonymous
  visitors to `/sign-in` with `return_to` preserving `?user_code=...`).
  Without a `user_code`, it renders the code-entry form. With one, it
  normalizes per RFC 8628 §6.1, validates existence, expiry, and
  pending status, and renders the consent card with a signed
  short-lived `consent_token`.

  `POST /oauth/device` verifies the signed token, decision, and session
  user, reloads the grant, and dispatches `approve_device_grant` or
  `deny_device_grant` before rendering the terminal completion or denial
  card. Nothing redirects to an external client callback.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Api.Scopes
  alias FluxVale.OAuth
  alias FluxVale.OAuth.Client
  alias FluxVale.OAuth.DeviceGrant
  alias FluxValeWeb.Plugs.OAuthRateLimit
  alias FluxValeWeb.UserAuth

  @consent_salt "oauth device consent"
  @consent_ttl 10 * 60

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    case OAuthRateLimit.allow?(conn, :authorize) do
      :ok -> handle_show(conn, params)
      {:error, retry_after} -> throttled(conn, retry_after)
    end
  end

  @spec decide(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def decide(conn, params) do
    case OAuthRateLimit.allow?(conn, :authorize) do
      :ok -> handle_decide(conn, params)
      {:error, retry_after} -> throttled(conn, retry_after)
    end
  end

  defp handle_show(conn, params) do
    session = get_session(conn)

    case UserAuth.resolve_user(session) do
      nil -> redirect_to_sign_in(conn)
      user -> show_for_user(conn, user, params["user_code"])
    end
  end

  defp show_for_user(conn, user, raw_code) when is_binary(raw_code) do
    trimmed = String.trim(raw_code)

    if trimmed == "" do
      render_code_entry(conn, user)
    else
      trimmed
      |> normalize_user_code()
      |> lookup_and_render(conn, user)
    end
  end

  defp show_for_user(conn, user, _non_binary), do: render_code_entry(conn, user)

  defp normalize_user_code(code) do
    cleaned =
      code
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9]/, "")

    case byte_size(cleaned) do
      8 ->
        <<left::binary-size(4), right::binary-size(4)>> = cleaned
        left <> "-" <> right

      _other ->
        cleaned
    end
  end

  defp lookup_and_render(normalized_code, conn, user) do
    case DeviceGrant.get_by_user_code(normalized_code, authorize?: false) do
      {:ok, grant} ->
        render_grant_status(conn, grant, user)

      {:error, _not_found} ->
        error_page(
          conn,
          400,
          "Code not recognized",
          "Check the code in your terminal and try again.",
          retry_path: ~p"/oauth/device"
        )
    end
  end

  defp render_grant_status(conn, grant, user) do
    now = DateTime.utc_now()

    cond do
      DateTime.compare(grant.expires_at, now) == :lt or grant.status == :expired ->
        expired_error_page(conn, retry_path: ~p"/oauth/device")

      grant.status != :pending ->
        already_used_error_page(conn, retry_path: ~p"/oauth/device")

      true ->
        client = Client.get_by_id!(grant.client_id, authorize?: false)
        render_device_consent(conn, grant, client, user)
    end
  end

  defp render_code_entry(conn, user) do
    conn
    |> assign(:flash, conn.assigns[:flash] || %{})
    |> put_resp_header("cache-control", "no-store")
    |> put_view(FluxValeWeb.OAuthHTML)
    |> render(:device_code, %{
      page_title: "Device verification - FluxVale",
      signed_in_as: user.username
    })
  end

  defp render_device_consent(conn, grant, client, user) do
    payload = %{
      user_id: user.id,
      grant_id: grant.id,
      user_code: grant.user_code,
      client_id: client.client_id,
      scopes: grant.scopes,
      resource: grant.resource
    }

    consent_token = Phoenix.Token.sign(FluxValeWeb.Endpoint, @consent_salt, payload)
    scopes = Enum.map(grant.scopes, &%{name: &1, description: Scopes.describe(&1)})

    conn
    |> assign(:flash, conn.assigns[:flash] || %{})
    |> put_resp_header("cache-control", "no-store")
    |> put_view(FluxValeWeb.OAuthHTML)
    |> render(:device_authorize, %{
      page_title: "Authorize #{client.client_name} - FluxVale",
      client_name: client.client_name,
      signed_in_as: user.username,
      user_code: grant.user_code,
      scopes: scopes,
      consent_token: consent_token
    })
  end

  defp handle_decide(conn, params) do
    case verify_consent(params["consent_token"]) do
      {:ok, payload} ->
        decide_verified(conn, payload, params["decision"])

      {:error, _reason} ->
        error_page(
          conn,
          400,
          "This consent request expired",
          "Start the connection again from your terminal."
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
          "Sign in again and restart the connection from your terminal."
        )
    end
  end

  defp decide_verified(conn, _payload, _decision) do
    error_page(conn, 400, "Choose allow or deny", "The consent decision was not recognized.")
  end

  defp finish_decision(conn, payload, user, decision) do
    case DeviceGrant.get_by_user_code(payload[:user_code], authorize?: false) do
      {:ok, grant} ->
        client = Client.get_by_id!(grant.client_id, authorize?: false)
        apply_decision(conn, grant, client, user, decision)

      {:error, _not_found} ->
        expired_error_page(conn)
    end
  end

  defp apply_decision(conn, grant, client, user, decision) do
    result =
      case decision do
        "approve" -> OAuth.approve_device_grant(grant, actor: user)
        "deny" -> OAuth.deny_device_grant(grant, actor: user)
      end

    case {decision, result} do
      {"approve", {:ok, _approved}} ->
        render_complete(conn, client)

      {"deny", {:ok, _denied}} ->
        render_denied(conn, client)

      {_decision, {:error, :expired}} ->
        expired_error_page(conn)

      {_decision, {:error, :stale}} ->
        already_used_error_page(conn)

      # coveralls-ignore-start - DB outage on an already-validated
      # consent; the page answers the retry arm.
      {_decision, {:error, _other}} ->
        error_page(
          conn,
          500,
          "The request could not be completed",
          "Try again from your terminal."
        )

        # coveralls-ignore-stop
    end
  end

  defp render_complete(conn, client) do
    conn
    |> assign(:flash, conn.assigns[:flash] || %{})
    |> put_resp_header("cache-control", "no-store")
    |> put_view(FluxValeWeb.OAuthHTML)
    |> render(:device_complete, %{
      page_title: "Connected to #{client.client_name} - FluxVale",
      client_name: client.client_name
    })
  end

  defp render_denied(conn, client) do
    conn
    |> assign(:flash, conn.assigns[:flash] || %{})
    |> put_resp_header("cache-control", "no-store")
    |> put_view(FluxValeWeb.OAuthHTML)
    |> render(:device_denied, %{
      page_title: "Access denied - FluxVale",
      client_name: client.client_name
    })
  end

  defp redirect_to_sign_in(conn) do
    return_to =
      case conn.query_string do
        "" -> conn.request_path
        query -> conn.request_path <> "?" <> query
      end

    encoded = URI.encode_www_form(return_to)
    redirect(conn, to: "/sign-in?return_to=" <> encoded)
  end

  defp throttled(conn, retry_after) do
    retry_header = Integer.to_string(retry_after)

    conn
    |> put_resp_header("retry-after", retry_header)
    |> error_page(
      429,
      "Too many authorization attempts",
      "Wait a moment, then try again from your terminal."
    )
  end

  defp expired_error_page(conn, opts \\ []) do
    error_page(
      conn,
      400,
      "This code has expired",
      "Start a new sign-in from your terminal to get a fresh code.",
      opts
    )
  end

  defp already_used_error_page(conn, opts \\ []) do
    error_page(
      conn,
      400,
      "This code has already been used",
      "Start a new sign-in from your terminal if you need to connect again.",
      opts
    )
  end

  defp error_page(conn, status, title, detail, opts \\ []) do
    conn
    |> assign(:flash, conn.assigns[:flash] || %{})
    |> put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> put_view(FluxValeWeb.OAuthHTML)
    |> render(:error, %{
      page_title: title <> " - FluxVale",
      title: title,
      detail: detail,
      retry_path: opts[:retry_path]
    })
  end
end
