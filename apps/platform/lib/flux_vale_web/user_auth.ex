defmodule FluxValeWeb.UserAuth do
  @moduledoc """
  The authenticated app surface's on_mount gate (#74): resolves the
  actor from the M2 token-backed session with the same chain the API
  `Authenticate` plug uses — `authenticate_resource_from_session/4`
  (token-store presence: a revoked session token severs LiveView use
  too, not just API) plus the AccessRule gate (#26). No actor → the
  sign-in flow.

  Assigns `current_user`; the browser pipeline never resolves it, so
  this is the only writer.
  """

  use FluxValeWeb, :verified_routes

  alias AshAuthentication.Plug.Helpers
  alias FluxVale.Identity.User
  alias FluxVale.Ops.AccessRules

  @doc """
  Resolves the session's user or halts with a redirect to /sign-in.
  """
  @spec on_mount(:ensure_authenticated, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:ensure_authenticated, _params, session, socket) do
    case resolve_user(session) do
      %User{} = user ->
        {:cont, Phoenix.Component.assign(socket, :current_user, user)}

      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  # The same chain the API session fallback rides: token-store presence
  # (revocation) then the AccessRule gate (a removed rule severs access
  # within TTL). Any failure is "not signed in" — no error surface.
  defp resolve_user(session) do
    with {:ok, user} <-
           Helpers.authenticate_resource_from_session(User, session, :flux_vale, []),
         :ok <- AccessRules.ensure_allowed(user.email) do
      user
    else
      _error -> nil
    end
  end
end
