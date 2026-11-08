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

  The pending storage-request count (#250) rides every admin page: the
  mount reads the queue's countable page once, and — when connected —
  a `:handle_info` hook re-reads it on every `storage_requests:queue`
  notification, so the sidebar badge moves without polling. No email:
  production mail is a local adapter (ADR-0046 D6).
  """

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
        actor_orgs: [],
        personal_org_id: nil,
        username: current_user && current_user.username,
        nav_section: nil,
        pending_storage_requests: pending_count(current_user)
      )

    {:cont, attach_queue_hook(socket)}
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
  defp handle_queue_notification(%Ash.Notifier.Notification{}, socket) do
    {:cont,
     Phoenix.Component.assign(
       socket,
       :pending_storage_requests,
       pending_count(socket.assigns.current_user)
     )}
  end

  defp handle_queue_notification(_message, socket), do: {:cont, socket}
end
