defmodule FluxValeWeb.Plugs.RequirePlatformAdmin do
  @moduledoc """
  The admin gate behind the TestInbox surfaces (#22, ADR-0023 Am. 3 — the
  viewer displays live login codes). The actor notion is the shared
  predicate `FluxVale.Checks.ActorIsPlatformAdmin.platform_admin?/1`, so
  plug-land and policy-land cannot fork on who is an admin.

  Two response vocabularies, per the pipeline it runs in:

  - `:json` — machine clients (E2E with an admin PAT, ADR-0003 Am. 2):
    401 with no/invalid credentials, 403 for an authenticated non-admin.
    Plain JSON, not JSON:API — the TestInbox is a first-party dev/ops
    surface, not the versioned client contract (#24 owns that vocabulary).
  - `:html` — humans: unsigned-in visitors bounce to /sign-in (the normal
    app entry); a signed-in non-admin gets a bare 403.

  Expects `FluxValeWeb.Plugs.Authenticate` upstream (`current_user`).
  """

  import Plug.Conn

  alias FluxVale.Checks.ActorIsPlatformAdmin

  @doc false
  @spec init(:json | :html) :: :json | :html
  def init(format) when format in [:json, :html], do: format

  @doc false
  @spec call(Plug.Conn.t(), :json | :html) :: Plug.Conn.t()
  def call(conn, format) do
    actor = conn.assigns[:current_user]

    cond do
      ActorIsPlatformAdmin.platform_admin?(actor) ->
        conn

      format == :html ->
        deny_html(conn, actor)

      is_nil(actor) ->
        json_denial(conn, :unauthorized, "Missing or invalid credentials")

      true ->
        json_denial(conn, :forbidden, "Platform admin required")
    end
  end

  # Unsigned-in human: the standard app entry — sign in, come back.
  defp deny_html(conn, nil) do
    conn
    |> put_resp_header("location", "/sign-in")
    |> send_resp(:found, "Found")
    |> halt()
  end

  # Humans get a bare 403 — a JSON error document on an HTML route would
  # be noise (CodeRabbit, #47)
  defp deny_html(conn, _non_admin) do
    conn
    |> send_resp(:forbidden, "")
    |> halt()
  end

  defp json_denial(conn, status, detail) do
    body = Jason.encode!(%{error: detail})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
