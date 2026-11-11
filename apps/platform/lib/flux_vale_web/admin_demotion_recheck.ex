defmodule FluxValeWeb.AdminDemotionRecheck do
  @moduledoc """
  The periodic demotion re-resolve on the generated admin tools
  (ADR-0027 Am. 5's residue, closed by the owner's Nov 11, 2026
  decision — Am. 6): AshAdmin's forms/generic actions and
  LiveDashboard's table controls are cid-targeted, and LiveView
  routes those straight to the component, so no view-level hook —
  `AdminDemotionGate` included — ever sees them. A demoted platform
  admin's already-open tab therefore kept acting until the socket
  reconnected. This hook closes that window from the socket side: a
  `Process.send_after` tick re-resolves the actor from the session
  (token revocation rides the resolve) every cadence, and the moment
  the role check fails the tab is REDIRECTED out of the admin area —
  the same `/sign-in` answer `AdminGate` gives at every mount (each
  arm spells the literal; if the sign-in route ever moves, both
  move together or neither does). The window is
  bounded to the cadence (default 30s, config below), not gated
  per-event — that bound is the accepted posture. Fail-closed like
  the gate it mirrors: ANY resolve failure (not just demotion — a
  token-store or DB blip reads as "not signed in") redirects the
  tab within one cadence; the cost list in Am. 6 owns that.

  Generated sessions only (ash_admin + live_dashboard live_sessions).
  The custom console keeps the quiet-freeze posture: its surfaces
  re-resolve per event already, and every write rides an authorized
  action, so a mid-session demotion there costs a refused event, not
  a write. The redirect changes what a demoted admin's open
  generated-tools tab experiences (a working tab is yanked to
  /sign-in within the cadence), which is exactly why it is an owner
  decision on record, not a slice insert.

  Mount order is load-bearing: AFTER `AdminGate` (a denied mount
  redirects before any timer arms) and BEFORE `AdminDemotionGate` —
  the seam's info gate halts every message under a dead session,
  quietly, so the recheck must see the tick first or its redirect
  would never run.

  The tick (`:admin_demotion_recheck`) is this module's alone — no
  vendor message collides — and BOTH of its arms halt: a passing tick
  must never fall through to the vendor view's own `handle_info`
  (AshAdmin's pageLive has no clause for foreign atoms — the message
  would crash it), and a failing tick carries the redirect. Halting
  the passing tick also keeps the seam behind us from re-resolving
  it: one resolve per tick, total. The tick touches no assigns — its
  only job is the role check; the seam refreshes `:current_user` on
  real events, and a demoted tab is about to redirect anyway.

  The timer is armed against `self()` inside the view process: a
  dropped session takes its pending tick to the grave (a dead mailbox
  discards it), so nothing outlives the socket and at most one tick
  is ever outstanding. Arming happens on connected mounts only — the
  dead render's process exits right after the response, so its timer
  would be noise. The cadence is read per arm, so a config change
  applies within one tick.
  """

  alias FluxVale.Checks.ActorIsPlatformAdmin
  alias FluxVale.Identity.User
  alias FluxValeWeb.UserAuth

  @tick :admin_demotion_recheck
  @default_cadence_ms 30_000

  @spec on_mount(:attach, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:attach, _params, session, socket) do
    socket =
      socket
      # The session map for the per-tick actor re-resolve — the same
      # assign AdminDemotionGate keeps; same value, idempotent here.
      |> Phoenix.Component.assign(:admin_session, session)
      |> Phoenix.LiveView.attach_hook(:admin_demotion_recheck, :handle_info, &recheck/2)
      |> arm_if_connected()

    {:cont, socket}
  end

  # One tick: re-resolve the actor, then either carry on or redirect.
  # Both arms halt — the tick is this hook's message alone (see the
  # moduledoc), never the vendor view's. Still admin — re-arm and done
  # (no assigns: nothing observable should change on a passing tick).
  # Not (or no longer resolvable) — the redirect AdminGate gives at
  # mount, and the channel honors a redirect set in a halted info hook
  # (verified against phoenix_live_view's channel.ex: the halted
  # socket's `redirected` field is pushed to the client).
  defp recheck(@tick, socket) do
    case UserAuth.resolve_user(socket.assigns.admin_session) do
      %User{} = actor ->
        if ActorIsPlatformAdmin.platform_admin?(actor) do
          {:halt, arm(socket)}
        else
          {:halt, Phoenix.LiveView.redirect(socket, to: "/sign-in")}
        end

      _not_signed_in ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/sign-in")}
    end
  end

  # Any other info message is not this hook's business — pass it
  # through untouched so the seam's info gate and the vendor view's
  # own handlers see exactly what they saw before this hook existed
  # (the dashboard's :refresh tick among them).
  defp recheck(_other_message, socket) do
    {:cont, socket}
  end

  # Arming is connected-mount-only: the dead render's process exits
  # right after the response — its timer would be noise.
  defp arm_if_connected(%Phoenix.LiveView.Socket{} = socket) do
    if Phoenix.LiveView.connected?(socket) do
      arm(socket)
    else
      socket
    end
  end

  # Fire-and-forget by design: send_after against self() dies with the
  # mailbox, so there is nothing to cancel on session drop and nothing
  # that can leak past the process.
  defp arm(socket) do
    Process.send_after(self(), @tick, cadence_ms())
    socket
  end

  defp cadence_ms do
    cadence = Application.get_env(:flux_vale, :admin_demotion_recheck_ms, @default_cadence_ms)

    # A misconfigured cadence (nil, or a non-positive integer someone
    # put_env'd onto a live node) degrades to the documented default
    # rather than raising inside on_mount — the admin surface must
    # mount; a bad tick discipline is an ops problem, not a 500.
    if is_integer(cadence) and cadence > 0 do
      cadence
    else
      @default_cadence_ms
    end
  end
end
