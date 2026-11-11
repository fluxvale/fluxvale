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
  messages only, and neither vendor layout renders a flash group —
  so a refusal on a generated surface is SILENT (the event simply
  does not happen); the copy renders on the console, whose layout
  carries the flash group. LiveDashboard: the refresh tick is an
  info message and nav is navigate-shaped (a remount through
  AdminGate), so a demoted tab stops auto-following and its
  view-level events — the refresh-rate select among them — are
  refused; but the table controls (search, sort, limit) are
  cid-targeted events that push_patch, and a patch re-runs
  handle_params ungated, so those still refresh node telemetry
  under a dead session. AshAdmin: the view-level chrome (sidebar,
  the authorizing toggle, actor/tenant ops) is refused; the rest of
  its component-level UI — save/destroy forms, generic actions,
  table filters, the sensitive-attribute reveal — is
  `phx-target={@myself}`, and LiveView routes cid-targeted events
  straight to the component, where no view-level hook can see them.
  Both residues stood disclosed on #671 until the owner's Nov 11,
  2026 decision (ADR-0027 Am. 6): `FluxValeWeb.AdminDemotionRecheck`
  re-resolves on a timer and redirects a dead generated-session tab
  out of the admin area within its cadence — the component-level
  window is now BOUNDED, not gated, which is the accepted posture.

  Cost, accepted: the resolve rides every info message, including
  the dashboard's refresh tick (default 15s, floor 1s) — a few
  queries per tick per open admin socket. The tick drives data
  re-reads, so leaving it ungated would reopen the very window this
  seam exists to close.
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

      # The revoked-token arm: the session no longer resolves (the
      # resolve re-checks token-store revocation), so the refusal is
      # the demoted actor's — pinned by the generated-tools suite's
      # revoke test.
      _not_signed_in ->
        {:halt, demoted(socket)}
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

      # The revoked-token arm, the event gate's own reasoning — the
      # session stops resolving; the halt is quiet either way. Pinned
      # by the generated-tools suite's revoke test (the info message
      # class) alongside the event arm.
      _not_signed_in ->
        {:halt, socket}
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
