defmodule FluxValeWeb.AdminChrome do
  @moduledoc """
  The admin surfaces' shared chrome assigns (ADR-0027 Am. 3, #501): the
  block every admin LiveView used to copy into its own mount, now one
  on_mount on the `:admin` live_session — the same sharing posture as
  `FluxValeWeb.UserAuth`'s `:ensure_authenticated` hook.

  Runs AFTER the AdminGate in the session's on_mount list, so it only
  ever resolves an already-verified platform admin. The assigns are
  console-neutral (no org/nav hooks mount on this session); a surface
  that needs a different `nav_section` overrides it in its own mount,
  which runs after this hook.

  The per-event demotion seam (ADR-0047 D4, #644's console slice):
  reads stay mount-resolved — a demoted admin's already-mounted tab
  keeps its stale DOM until the next interaction — but EVERY event
  re-resolves the actor from the session and refuses a fresh struct
  that is no longer platform admin. Every admin LiveView inherits the
  seam here; no surface re-implements it.

  The pending storage-request count (#250) rides every admin page: the
  mount reads the queue's countable page once, and — when connected —
  a `:handle_info` hook re-reads it on every `storage_requests:queue`
  notification, so the sidebar badge moves without polling. No email:
  production mail is a local adapter (ADR-0046 D6).
  """

  use Gettext, backend: FluxValeWeb.Gettext

  alias FluxVale.Checks.ActorIsPlatformAdmin
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.StorageRequest
  alias FluxValeWeb.UserAuth

  @queue_topic "storage_requests:queue"

  @spec on_mount(:assign_chrome, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:assign_chrome, _params, session, socket) do
    current_user = UserAuth.resolve_user(session)

    socket =
      Phoenix.Component.assign(socket,
        current_user: current_user,
        # The session map, kept for the per-event actor re-resolve (see
        # `demotion_gate/3`) — the same posture the wallet surface
        # pioneered per-write, now shared by every event.
        admin_session: session,
        actor_orgs: [],
        personal_org_id: nil,
        username: current_user && current_user.username,
        nav_section: nil,
        pending_storage_requests: pending_count(current_user)
      )

    {:cont,
     socket
     |> attach_demotion_hook()
     |> attach_queue_hook()}
  end

  # The demotion window's interactive half (the wallet surface's write
  # gate, generalized): AdminGate re-checks the actor per MOUNT, and a
  # socket outlives a demotion — so every event re-resolves from the
  # session (which also re-checks token revocation) and requires the
  # platform-admin role on the fresh struct. The fresh struct replaces
  # :current_user, so the surface's handler both MAY and MUST act with
  # it. The refusal copy is the wallet surface's, byte-for-byte — one
  # grammar for the whole console.
  defp attach_demotion_hook(socket) do
    Phoenix.LiveView.attach_hook(
      socket,
      :admin_demotion_gate,
      :handle_event,
      &demotion_gate/3
    )
  end

  defp demotion_gate(_event, _params, socket) do
    case UserAuth.resolve_user(socket.assigns.admin_session) do
      %User{} = actor ->
        if ActorIsPlatformAdmin.platform_admin?(actor) do
          {:cont, Phoenix.Component.assign(socket, :current_user, actor)}
        else
          {:halt, demoted(socket)}
        end

      # The revoked-token arm: same refusal as the demoted actor, and
      # unreachable in a test without revoking the live session's jti
      # out-of-band — the demoted-actor tests carry the gate's behavior.
      # coveralls-ignore-start
      _not_signed_in ->
        {:halt, demoted(socket)}
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

  defp attach_queue_hook(socket) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(FluxVale.PubSub, @queue_topic)

      Phoenix.LiveView.attach_hook(
        socket,
        :storage_request_badge,
        :handle_info,
        &handle_queue_notification/2
      )
    else
      socket
    end
  end

  @doc """
  The queue's pending count: requests awaiting an operator decision. A
  read failure (the DB-down or demoted-actor class) answers 0 rather
  than crashing every admin page's mount — the surface's own reads are
  the loud path.
  """
  @spec pending_count(FluxVale.Identity.User.t() | nil) :: non_neg_integer()
  def pending_count(nil), do: 0

  def pending_count(admin) do
    case StorageRequest.queue(%{status: :requested}, actor: admin) do
      {:ok, page} -> page.count || 0
      # coveralls-ignore-next-line - the demoted-actor/DB-down class; the
      # admin gate admits only platform admins at mount and the queue's
      # own reads surface a real failure loudly.
      {:error, _reason} -> 0
    end
  end

  # The hook re-reads the count on every queue notification (create,
  # decision, apply) — the DB is the ordering that cannot lie, so the
  # notification's payload is never trusted for the number.
  defp handle_queue_notification(
         %Ash.Notifier.Notification{resource: StorageRequest},
         socket
       ) do
    {:cont,
     Phoenix.Component.assign(
       socket,
       :pending_storage_requests,
       pending_count(socket.assigns.current_user)
     )}
  end

  defp handle_queue_notification(_message, socket), do: {:cont, socket}
end
