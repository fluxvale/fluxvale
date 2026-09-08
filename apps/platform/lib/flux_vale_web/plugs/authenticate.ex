defmodule FluxValeWeb.Plugs.Authenticate do
  @moduledoc """
  Resolves the current user for API requests — PAT bearer-first,
  session-fallback (v1's shape, ported per #24).

  Bearer: `retrieve_from_bearer/3` verifies the JWT and, under
  `require_token_presence_for_authentication?`, requires a live
  token-store row — a revoked PAT never authenticates.

  Session: v2 sessions are token-backed (`store_in_session/2`), so the
  fallback also resolves through the token store — unlike v1's raw
  `user_id` lookup, which bypassed revocation. A revoked session token
  severs API use too (the deliberately ported upgrade, #24).

  An invalid bearer falls back to the session, exactly as in v1: the
  header wins when it authenticates, absence or failure does not.

  #26 seam: the AccessRule check at the PAT-auth boundary lands here,
  after user resolution (short-TTL cache) — it must gate sessions too,
  which share this path.
  """

  alias AshAuthentication.Plug.Helpers

  @doc false
  @spec init(keyword) :: keyword
  def init(opts), do: opts

  @doc """
  Resolves the current user (bearer-first, session-fallback), assigns
  `conn.assigns.current_user`, and sets the Ash actor for ash_json_api.
  """
  @spec call(Plug.Conn.t(), keyword) :: Plug.Conn.t()
  def call(conn, _opts) do
    conn
    |> from_bearer()
    |> from_session()
    |> set_actor()
  end

  defp from_bearer(conn) do
    if bearer_token?(conn) do
      conn
      |> canonicalize_bearer_scheme()
      |> Helpers.retrieve_from_bearer(:flux_vale)
    else
      conn
    end
  end

  # RFC 7235: auth-scheme names are case-insensitive; the ash_authentication
  # helper parses only the canonical "Bearer " prefix — normalize before it
  # sees the header (CodeRabbit, #44)
  defp bearer_token?(conn) do
    conn
    |> Plug.Conn.get_req_header("authorization")
    |> Enum.any?(&bearer_scheme?/1)
  end

  defp bearer_scheme?(header) do
    header
    |> String.downcase()
    |> String.starts_with?("bearer ")
  end

  defp canonicalize_bearer_scheme(conn) do
    req_headers =
      Enum.map(conn.req_headers, fn
        {"authorization", "bearer" <> rest} -> {"authorization", "Bearer" <> rest}
        header -> header
      end)

    %{conn | req_headers: req_headers}
  end

  # Only falls back when the bearer path resolved nothing — a successful
  # bearer auth must not be re-resolved from whatever session rode along.
  defp from_session(%Plug.Conn{assigns: %{current_user: user}} = conn) when not is_nil(user),
    do: conn

  defp from_session(conn), do: Helpers.retrieve_from_session(conn, :flux_vale)

  defp set_actor(conn),
    do: Ash.PlugHelpers.set_actor(conn, conn.assigns[:current_user])
end
