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
  """

  alias FluxValeWeb.UserAuth

  @spec on_mount(:assign_chrome, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:assign_chrome, _params, session, socket) do
    current_user = UserAuth.resolve_user(session)

    {:cont,
     Phoenix.Component.assign(socket,
       current_user: current_user,
       actor_orgs: [],
       personal_org_id: nil,
       username: current_user && current_user.username,
       nav_section: nil
     )}
  end
end
