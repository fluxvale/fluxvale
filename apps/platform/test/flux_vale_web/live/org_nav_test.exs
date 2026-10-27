defmodule FluxValeWeb.OrgNavTest do
  @moduledoc """
  The chrome's org-data hook (#276): assigns the actor's memberships
  (org loaded) and never halts — the empty case included.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxValeWeb.OrgNav

  require Ash.Query

  test "assigns the actor's orgs (org + role per row)" do
    user = AccountsFixtures.user!()
    org = AccountsFixtures.personal_org!(user)

    assert {:cont, socket} = OrgNav.on_mount(:assign_orgs, %{}, %{}, socket_with(user))
    assert [%{role: :owner, organization: %{id: org_id}}] = socket.assigns.actor_orgs
    assert org_id == org.id
  end

  test "zero orgs assigns an empty list" do
    # Unreachable through actions (JIT provisioning members the creator);
    # the empty shape is the chrome's defensive state and the test says so.
    user = AccountsFixtures.user!()
    org = AccountsFixtures.personal_org!(user)
    drop_membership!(user, org)

    assert {:cont, socket} = OrgNav.on_mount(:assign_orgs, %{}, %{}, socket_with(user))
    assert socket.assigns.actor_orgs == []
  end

  defp socket_with(user) do
    Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, :current_user, user)
  end

  defp drop_membership!(user, org) do
    membership =
      FluxVale.Accounts.Membership
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(user_id == ^user.id and organization_id == ^org.id)
      |> Ash.read_one!(authorize?: false)

    # System posture — the destroy policy is system-only (#119).
    Ash.destroy!(membership, authorize?: false)
  end
end
