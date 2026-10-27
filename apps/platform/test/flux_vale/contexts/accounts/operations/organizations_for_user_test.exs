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

    test "a co-member cannot read the other member's row — the actor scopes the rows" do
      owner = AccountsFixtures.user!()
      _owner_org = AccountsFixtures.personal_org!(owner)
      member = AccountsFixtures.user!()
      member_org = AccountsFixtures.personal_org!(member)
      shared = shared_org!(owner, member)

      # The read policy authorizes orgs, not rows: both co-members pass
      # it for the shared org, so only the actor scoping keeps the row
      # set to the actor's own memberships.
      assert {:ok, []} = Accounts.organizations_for_user(owner.id, actor: member)

      assert {:ok, rows} = Accounts.organizations_for_user(member.id, actor: member)
      org_ids = Enum.map(rows, & &1.organization.id)

      assert Enum.sort(org_ids) == Enum.sort([member_org.id, shared.id])
    end

    test "another actor's id yields nothing (the read policy filter-checks)" do
      user = AccountsFixtures.user!()
      _org = AccountsFixtures.personal_org!(user)
      stranger = AccountsFixtures.user!()

      assert {:ok, []} = Accounts.organizations_for_user(user.id, actor: stranger)
    end

    test "no actor with the default authorize? is Forbidden (the policy gate)" do
      user = AccountsFixtures.user!()
      _org = AccountsFixtures.personal_org!(user)

      assert {:error, %Ash.Error.Forbidden{}} = Accounts.organizations_for_user(user.id)
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

  defp shared_org!(owner, member) do
    org =
      Organization.create!(
        %{name: "Team Org", slug: "team-#{System.unique_integer([:positive])}"},
        authorize?: false
      )

    Membership.create!(%{organization_id: org.id, user_id: owner.id, role: :owner},
      authorize?: false
    )

    Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
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
