defmodule FluxVale.Accounts.Operations.OrganizationsForUserTest do
  @moduledoc """
  The org switcher's read (#276): the actor's memberships with the org
  loaded, one authorized query, authorization riding the caller's opts.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  describe "call/2" do
    test "returns the actor's membership with the org loaded" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      assert {:ok, [membership]} = Accounts.organizations_for_user(user.id, actor: user)

      assert membership.role == :owner
      assert membership.user_id == user.id
      assert membership.organization.id == org.id
      assert membership.organization.slug == org.slug
    end

    test "lists every membership — a second org rides with its own role" do
      user = AccountsFixtures.user!()
      personal = AccountsFixtures.personal_org!(user)
      team = member_org!(user, role: :member)

      assert {:ok, memberships} = Accounts.organizations_for_user(user.id, actor: user)
      assert length(memberships) == 2

      roles_by_org = Map.new(memberships, &{&1.organization.id, &1.role})

      assert roles_by_org[personal.id] == :owner
      assert roles_by_org[team.id] == :member
    end

    test "another actor's id yields nothing (the read policy filter-checks)" do
      user = AccountsFixtures.user!()
      _org = AccountsFixtures.personal_org!(user)
      stranger = AccountsFixtures.user!()

      assert {:ok, []} = Accounts.organizations_for_user(user.id, actor: stranger)
    end

    test "authorize?: false reads as the system caller (bootstrap posture)" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      assert {:ok, [%{organization: %{id: org_id}}]} =
               Accounts.organizations_for_user(user.id, authorize?: false)

      assert org_id == org.id
    end

    test "zero memberships is an empty list" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      membership = membership!(user, org)

      # System posture (authorize?: false) — the destroy policy is
      # system-only, and the state is unreachable through actions (JIT
      # provisioning members the creator at signup). This is the chrome's
      # defensive empty shape.
      Ash.destroy!(membership, authorize?: false)

      assert {:ok, []} = Accounts.organizations_for_user(user.id, actor: user)
    end
  end

  # Both creates are system-only (#119) — no actor reaches them, so the
  # precondition rides the bootstrap posture, mirroring seeds.
  defp member_org!(user, role: role) do
    org =
      Organization.create!(
        %{name: "Team Org", slug: "team-#{System.unique_integer([:positive])}"},
        authorize?: false
      )

    Membership.create!(%{organization_id: org.id, user_id: user.id, role: role},
      authorize?: false
    )

    org
  end

  defp membership!(user, org) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(user_id == ^user.id and organization_id == ^org.id)
    |> Ash.read_one!(authorize?: false)
  end
end
