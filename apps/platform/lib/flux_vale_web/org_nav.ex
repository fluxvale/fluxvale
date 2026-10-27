defmodule FluxValeWeb.OrgNav do
  @moduledoc """
  The app chrome's org data (#276): resolves the actor's org memberships
  (org loaded) into `actor_orgs` for the `org_switcher`. Same on_mount
  shape as `FluxValeWeb.UserAuth`; wire it after UserAuth in the same
  on_mount lists — it reads `current_user` and never resolves identity
  itself.

  Data, not a gate: it never halts or redirects. Zero memberships assign
  `[]` — unreachable for action-created users (signup's JIT provisioning
  members the creator), real for seeded/legacy rows — and the switcher
  renders its Personal entry alone.
  """

  alias FluxVale.Accounts

  @doc """
  Resolves `current_user`'s orgs into `actor_orgs`. Never halts.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:assign_orgs, _params, _session, socket) do
    user = socket.assigns.current_user

    orgs =
      case Accounts.organizations_for_user(user.id, actor: user) do
        {:ok, memberships} ->
          memberships

        # defensive: DB read failure, not simulatable under the sandbox
        # coveralls-ignore-start
        {:error, _reason} ->
          []
          # coveralls-ignore-stop
      end

    {:cont, Phoenix.Component.assign(socket, :actor_orgs, orgs)}
  end
end
