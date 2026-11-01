defmodule FluxValeWeb.AdminGate do
  @moduledoc """
  The admin surfaces' on_mount socket re-check (#288, ADR-0027 §2
  Am. 2).

  The route pipeline gates the HTTP request (session auth + the
  platform-admin role), but a LiveView socket is a session of its own:
  a session token issued to a since-demoted admin can still mount the
  admin pages — the socket never re-enters the router. This hook
  re-runs the actor check at every socket mount (page loads,
  reconnects — not intra-page navigation, which stays inside one
  mount), the same posture as the app's own `:authenticated` surface
  (`FluxValeWeb.UserAuth`'s on_mount): per-mount, not per-event.

  The actor resolves from the token-backed session via
  `UserAuth.resolve_user/1` (token-store revocation rides along),
  never a bearer header — the socket carries the session, and this
  surface is human/browser use by design. A session that no longer
  resolves to a platform admin redirects to sign-in at mount (a halt
  WITHOUT a redirect raises in LiveView's mount lifecycle — every
  denial arm must redirect); the next HTTP request gets the route
  gate's precise answer (sign-in bounce vs 403).

  Am. 2 (Nov 1, 2026): the ADMIN_MOUNT_KEY runtime mount gate this
  hook also checked is RETIRED — the admin surface is always mounted
  and the platform-admin auth is the gate. The socket re-check stays:
  it guards the same demotion window the key never could.
  """

  alias FluxVale.Checks.ActorIsPlatformAdmin
  alias FluxValeWeb.UserAuth

  @doc """
  Re-checks the platform-admin actor at socket mount; redirects away
  unless it holds.
  """
  @spec on_mount(:ensure_admin, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:ensure_admin, _params, session, socket) do
    if platform_admin?(session) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/sign-in")}
    end
  end

  defp platform_admin?(session) do
    session
    |> UserAuth.resolve_user()
    |> ActorIsPlatformAdmin.platform_admin?()
  end
end
