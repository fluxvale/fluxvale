defmodule FluxValeWeb.OrgNav do
  @moduledoc """
  The app chrome's org data (#276): resolves the actor's org memberships
  (org loaded) into `actor_orgs` for the `org_switcher`. Same on_mount
  shape as `FluxValeWeb.UserAuth`; wire it after UserAuth in the same
  on_mount lists — it reads the user UserAuth resolved.

  Data, not a gate: it never halts, redirects, or raises. No
  `current_user` (a miswiring — UserAuth runs first on every sanctioned
  site) and zero memberships alike assign `[]`, and the switcher renders
  its Personal entry alone. Zero orgs is unreachable for action-created
  users (signup's JIT provisioning members the creator); real for
  seeded/legacy rows.
  """

  alias FluxVale.Accounts

  require Logger

  @doc """
  Resolves `current_user`'s orgs into `actor_orgs`. Never halts.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:assign_orgs, _params, _session, socket) do
    orgs =
      case socket.assigns[:current_user] do
        nil ->
          []

        user ->
          case Accounts.organizations_for_user(user.id, actor: user) do
            {:ok, memberships} ->
              memberships

            # Unreachable for a %User{} actor — the rows are scoped to
            # the actor's own memberships, which always pass the read
            # policy — and a DB failure is not simulatable under the
            # sandbox. Log + degrade: the switcher is chrome, not a gate.
            # coveralls-ignore-start
            {:error, reason} ->
              Logger.warning("OrgNav org lookup failed: #{inspect(reason)}")
              []
              # coveralls-ignore-stop
          end
      end

    {:cont, Phoenix.Component.assign(socket, :actor_orgs, orgs)}
  end
end
