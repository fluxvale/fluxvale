defmodule FluxValeWeb.Api.DeviceFlowController do
  @moduledoc """
  The RFC 8628 wire's two plain-JSON endpoints (#362 T3, OQ #9's
  pre-decided shape) — the CLI's `auth login` rides these:

  * `POST /api/v1/device/code` — mint a sign-in request (§3.1/§3.2)
  * `POST /api/v1/device/token` — the poll (§3.5)

  Deliberately NOT the ash_json_api router: the bodies are bare
  `application/json` (RFC 8628 shapes — a JSON:API document would be
  wrong on the wire), and the callers are unauthenticated BY DESIGN —
  the device has no token yet, this flow is how it earns one. The
  router mounts the pair outside the /api/v1 forward on the plain
  :api pipeline (the why lives there).

  No ApiAudit/ApiRateLimit either — both key on a PAT, which the flow
  doesn't have; v1 answers with a Logger line per mint/poll cycle
  (never a code or token value). IP limiting is the named follow-up.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Identity
  alias FluxVale.Identity.DeviceCode

  require Logger

  @doc "RFC 8628 §3.1/§3.2 — the device authorization response"
  def create_code(conn, params) do
    scopes = params["scopes"] || []

    if is_list(scopes) do
      answer_create(conn, params, scopes)
    else
      # The wire's scopes is an array (§3.1); anything else is the
      # same §5.2 error shape, not a 500.
      oauth_error(conn, :invalid_scope, "scopes must be an array of scope strings")
    end
  end

  defp answer_create(conn, params, scopes) do
    case Identity.mint_device_code(%{
           client_id: params["client_id"],
           scopes: scopes
         }) do
      {:ok, row} ->
        # The v1 audit surface: one log line per mint cycle — the
        # request shape only, never either code value (the
        # device_code is the poll capability, the user_code half of
        # the human comparison).
        Logger.info("device code minted via /device/code: client=#{row.client_id}")

        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("pragma", "no-cache")
        |> json(%{
          device_code: row.device_code,
          user_code: row.user_code,
          verification_uri: verification_uri(conn),
          expires_in: DeviceCode.ttl_seconds(),
          interval: Identity.device_poll_interval_seconds()
        })

      {:error, {:invalid_client, _client_id}} ->
        oauth_error(conn, :invalid_client, "unknown client")

      {:error, {:invalid_scope, scope}} ->
        oauth_error(conn, :invalid_scope, "unknown scope #{scope}")

      {:error, {:duplicate_scope, scope}} ->
        oauth_error(conn, :invalid_scope, "duplicate scope #{scope}")

      # Defensive: the resource-level guards are the mint operation's
      # own checks repeated — a caller that trips them here refused
      # the same refusal the operation already names. Generic
      # invalid_request keeps the RFC error shape.
      # coveralls-ignore-start
      {:error, _changeset} ->
        oauth_error(conn, :invalid_request, "malformed request")

        # coveralls-ignore-stop
    end
  end

  @doc "RFC 8628 §3.5 — the poll"
  def poll_token(conn, params) do
    if params["grant_type"] == Identity.device_grant_type() do
      answer_poll(conn, params)
    else
      # OAuth §5.2 — the poll is a grant request, and this grant_type
      # is the only one the endpoint speaks.
      oauth_error(
        conn,
        :unsupported_grant_type,
        "grant_type must be #{Identity.device_grant_type()}"
      )
    end
  end

  defp answer_poll(conn, params) do
    case Identity.poll_device_code(params["client_id"], params["device_code"]) do
      {:ok, %{status: :authorization_pending}} ->
        Logger.info("device poll: authorization_pending")

        oauth_error(conn, :authorization_pending, "approval still pending")

      {:error, :slow_down} ->
        Logger.info("device poll: slow_down")

        oauth_error(
          conn,
          :slow_down,
          "polled sooner than the interval. Back off #{Identity.device_poll_interval_seconds()} seconds"
        )

      {:error, :access_denied} ->
        Logger.info("device poll: access_denied")

        oauth_error(conn, :access_denied, "the sign-in request was denied")

      {:error, :expired_token} ->
        Logger.info("device poll: expired_token")

        oauth_error(conn, :expired_token, "the device code is expired or already used")

      {:error, {:invalid_client, _client_id}} ->
        oauth_error(conn, :invalid_client, "unknown client")

      # Defensive: the poll's own record write failed (DB outage) —
      # not an RFC state; a 500 in the same error envelope keeps the
      # client's retry loop meaningful (coveralls-ignore: not
      # simulatable — the suite cannot take the DB down, AGENTS).
      # coveralls-ignore-start
      {:error, {:poll_write_failed, error}} ->
        Logger.error("device poll write failed: #{inspect(error)}")

        conn
        |> put_status(500)
        |> json(%{error: "server_error", error_description: "transient server error"})

      # coveralls-ignore-stop

      # Defensive: the grant's mint failed mid-flow (DB outage) — the
      # approval is burned (consume-first), the client restarts the
      # flow. Same 500 envelope (coveralls-ignore: not simulatable).
      # coveralls-ignore-start
      {:error, {:mint_failed, error}} ->
        Logger.error("device flow mint failed: #{inspect(error)}")

        conn
        |> put_status(500)
        |> json(%{error: "server_error", error_description: "transient server error"})

      # coveralls-ignore-stop

      # The one-time grant — the raw value crosses the wire HERE, on
      # this one response, and never again (the row is :consumed).
      # RFC 6749 §5.1 / RFC 8628 §3.5: token responses are no-store.
      {:ok, %{token: raw, pat: pat, expires_in: expires_in}} ->
        Logger.info("device poll: token issued pat=#{pat.id}")

        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("pragma", "no-cache")
        |> json(%{
          access_token: raw,
          token_type: "Bearer",
          scope: Enum.join(pat.scopes, " "),
          expires_in: expires_in
        })
    end
  end

  # The RFC 8628 §3.1 error envelope — OAuth §5.2's shape, status 400
  # (RFC 8628 §3.5: token-endpoint errors are 400s).
  defp oauth_error(conn, error, description) do
    conn
    |> put_status(400)
    |> json(%{error: to_string(error), error_description: description})
  end

  # The approval panel's URL on the REQUESTING environment's origin —
  # the host the CLI talked to. The user_code lives in this
  # environment's DB, so the human must open this environment's page:
  # prod's canonical origin is the SEO posture (ADR-00025), not a DB
  # pointer. conn.host is the same request fact EdgeHost dispatches
  # on (#203); Traefik passes it through untouched. Scheme is always
  # https — every served environment terminates TLS at the edge (the
  # local k3d stack included); a bare-http dev server would print an
  # https URL no browser opens.
  defp verification_uri(conn) do
    "https://" <> conn.host <> "/settings/access/device"
  end
end
