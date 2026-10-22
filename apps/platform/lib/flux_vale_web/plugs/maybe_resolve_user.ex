defmodule FluxValeWeb.Plugs.MaybeResolveUser do
  @moduledoc """
  Display-only session resolution for the public pages' chrome (#164):
  reuses `FluxValeWeb.UserAuth.resolve_user/1` to put the session's user
  (or nil) into `:current_user`, so the public chrome can show the user
  menu of a signed-in visitor (#205) — and `PageController` can swap
  `/` from the landing to the dashboard.

  A display hint, never an auth gate — the on_mount gate on the
  authenticated `live_session` stays the only auth writer.
  """

  import Plug.Conn

  alias FluxValeWeb.UserAuth

  @doc false
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @doc "Assigns `:current_user` (user or nil) from the fetched session, if any."
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    # get_session/1 reads the fetched session (:browser runs first in the
    # public pages' pipeline, so it is fetched; it raises unfetched — the
    # pipeline order is part of this plug's contract).
    session = get_session(conn)
    assign(conn, :current_user, UserAuth.resolve_user(session))
  end
end
