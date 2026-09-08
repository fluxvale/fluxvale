defmodule FluxValeWeb.TestInboxController do
  @moduledoc """
  The TestInbox JSON endpoint (#22, ADR-0024 Am. 1): the stable
  first-party read for the future E2E adapters — the captured list, plus
  latest-mail/code for an address as the deterministic login-poll shape.
  Machines reach it with an admin PAT (ADR-0003 Am. 2: PATs need no
  session, so the staging bootstrap deadlock doesn't apply).

  Plain `application/json` by explicit content type, deliberately not
  JSON:API — and outside `/api/v1`: this is a config-gated dev/ops
  surface, not the versioned client contract (#24 owns that surface and
  its media type).
  """

  use FluxValeWeb, :controller

  alias FluxVale.TestInbox

  @doc false
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    mails = TestInbox.list_mails(params["email"])

    send_json(conn, 200, %{mails: mails})
  end

  @doc false
  @spec latest(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def latest(conn, params) do
    case TestInbox.latest_mail(params["email"] || "") do
      {:ok, mail} ->
        send_json(conn, 200, %{mail: mail})

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "no captured mail for #{params["email"]}"})
    end
  end

  # Explicit over Plug.Conn.send_resp + Jason: the app's "json" format
  # maps to application/vnd.api+json (config.exs, per the ash_json_api
  # installer) — this surface must not inherit the client API's media type.
  defp send_json(conn, status, data) do
    body = Jason.encode!(data)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end
end
