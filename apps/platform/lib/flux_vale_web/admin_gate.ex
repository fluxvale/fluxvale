defmodule FluxValeWeb.AdminGate do
  @moduledoc """
  The AshAdmin mount's on_mount re-check (#288, ADR-0027 §2 Am. 1).

  The route pipeline gates the HTTP request, but a LiveView socket is
  a session of its own: a session token issued while the mount was
  live can still mount the admin pages after the gate closes or the
  actor is demoted — the socket never re-enters the router. This hook
  re-runs both checks at every socket mount (page loads, reconnects —
  not intra-page navigation, which stays inside one mount), the same
  posture as the app's own `:authenticated` surface
  (`FluxValeWeb.UserAuth`'s on_mount): per-mount, not per-event.

  The actor resolves from the token-backed session via
  `UserAuth.resolve_user/1` (token-store revocation and the AccessRule
  gate ride along), never a bearer header — the socket carries the
  session, and this surface is human/browser use by design. A session
  that no longer resolves to a platform admin redirects to sign-in at
  mount (a halt WITHOUT a redirect raises in LiveView's mount
  lifecycle — every denial arm must redirect); the next HTTP request
  gets the route gate's precise answer (sign-in bounce vs 403).
  """

  alias FluxVale.Checks.ActorIsPlatformAdmin
  alias FluxValeWeb.Plugs.AdminEnabled
  alias FluxValeWeb.UserAuth

  @doc """
  Re-checks the mount gate and the platform-admin actor at socket
  mount; redirects away unless both hold.
  """
  @spec on_mount(:ensure_admin, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:ensure_admin, _params, session, socket) do
    cond do
      not AdminEnabled.enabled?() ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/")}

      not platform_admin?(session) ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/sign-in")}

      true ->
        {:cont, socket}
    end
  end

  defp platform_admin?(session) do
    session
    |> UserAuth.resolve_user()
    |> ActorIsPlatformAdmin.platform_admin?()
  end
end
