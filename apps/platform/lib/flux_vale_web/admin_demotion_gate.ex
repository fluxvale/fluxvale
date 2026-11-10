defmodule FluxValeWeb.AdminDemotionGate do
  @moduledoc """
  The per-event demotion seam every admin live_session shares
  (ADR-0047 D4, #644's console slice; #671 extends it past the custom
  console): reads stay mount-resolved — a demoted admin's
  already-mounted tab keeps its stale DOM until the next interaction —
  but EVERY event and every `:handle_info` notification re-resolves the
  actor from the session (which also re-checks token revocation) and
  refuses a fresh struct that is no longer platform admin. Events answer
  with the refusal copy; a halted notification is a quiet freeze — the
  tab stops following live writes, and the next explicit event hits the
  event gate's copy.

  Mount order is load-bearing: this hook sits AFTER AdminGate in every
  session's on_mount list, so the gate's mount re-check has already run
  when the hooks attach (and a denied mount stops this hook from
  attaching at all). Every admin live_session declares it exactly once —
  the console's `:admin` session, AshAdmin at /admin/ash, and
  LiveDashboard at /admin/debug/dashboard; attaching twice raises
  (LiveView hook ids are unique per socket), so a duplicate declaration
  fails loud at mount, never silently.

  Honest coverage on the generated tools (#671, measured against
  LiveView's channel): the hooks see VIEW-targeted events and info
  messages only. LiveDashboard's interaction is view-shaped (nav,
  refresh rate, the page events) and its `:refresh` tick is a message —
  under demotion the dashboard stops answering events and stops
  following live data. AshAdmin's resource writes (the save/destroy
  forms, the generic actions) are `phx-target={@myself}`: LiveView
  routes cid-targeted events straight to the component, and no
  view-level hook ever sees them — those events stay outside this seam
  (and outside any view-level seam). Closing that residue needs a
  socket-level answer — a periodic re-resolve that redirects, or a
  demotion broadcast the tab hears — a posture decision deliberately
  not made in this slice; disclosed on #671 instead.
  """

  use Gettext, backend: FluxValeWeb.Gettext

  alias FluxVale.Checks.ActorIsPlatformAdmin
  alias FluxVale.Identity.User
  alias FluxValeWeb.UserAuth

  @spec on_mount(:attach, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:attach, _params, session, socket) do
    socket =
      socket
      # The session map, kept for the per-event actor re-resolve (see
      # `demotion_gate/3`) — the same posture the wallet surface
      # pioneered per-write, now every admin surface's per-event gate.
      |> Phoenix.Component.assign(:admin_session, session)
      |> Phoenix.LiveView.attach_hook(
        :admin_demotion_gate,
        :handle_event,
        &demotion_gate/3
      )
      |> Phoenix.LiveView.attach_hook(
        :admin_demotion_info_gate,
        :handle_info,
        &demotion_info_gate/2
      )

    {:cont, socket}
  end

  # AdminGate re-checks the actor per MOUNT, and a socket outlives a
  # demotion — so every event re-resolves from the session and requires
  # the platform-admin role on the fresh struct. The fresh struct
  # replaces :current_user, so a surface's handler both MAY and MUST
  # act with it. The refusal copy is the wallet surface's,
  # byte-for-byte — one grammar for the whole console.
  defp demotion_gate(_event, _params, socket) do
    case UserAuth.resolve_user(socket.assigns.admin_session) do
      %User{} = actor ->
        if ActorIsPlatformAdmin.platform_admin?(actor) do
          {:cont, Phoenix.Component.assign(socket, :current_user, actor)}
        else
          {:halt, demoted(socket)}
        end

      # coveralls-ignore-start - the revoked-token arm: same refusal as
      # the demoted actor, unreachable without revoking the live
      # session's jti out-of-band (the demoted-actor tests carry the
      # gate's behavior).
      _not_signed_in ->
        {:halt, demoted(socket)}
        # coveralls-ignore-stop
    end
  end

  # The info-path seam: without it, a demoted admin's open tab keeps
  # FOLLOWING live writes, fed by notifications no gate ever saw. A
  # demoted fresh struct halts the notification quietly (no flash: a
  # notification is not user interaction, and every broadcast would
  # re-flash the same dead-session copy); the tab freezes on its last
  # mounted state and the next explicit event hits the copy above.
  defp demotion_info_gate(_message, socket) do
    case UserAuth.resolve_user(socket.assigns.admin_session) do
      %User{} = actor ->
        if ActorIsPlatformAdmin.platform_admin?(actor) do
          {:cont, Phoenix.Component.assign(socket, :current_user, actor)}
        else
          {:halt, socket}
        end

      # coveralls-ignore-start - the revoked-token arm, the event
      # gate's own reasoning: not reachable without revoking the live
      # session's jti out-of-band.
      _not_signed_in ->
        {:halt, socket}
        # coveralls-ignore-stop
    end
  end

  defp demoted(socket) do
    Phoenix.LiveView.put_flash(
      socket,
      :error,
      gettext("Your admin access ended. Sign out and sign back in.")
    )
  end
end
