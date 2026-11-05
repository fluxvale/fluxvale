defmodule FluxVale.Accounts.Operations.OwnedOrgsForUserTest do
  @moduledoc """
  The feedback islands' org picker read (#412 T5): the orgs the actor
  OWNS, oldest (the personal org) first, authorization riding the
  caller's opts.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.TestSupport.AccountsFixtures

  # Both org/membership creates are system-only (mirroring seeds) —
  # the bootstrap posture, as in OrganizationsForUserTest.
  defp owned_org!(user) do
    n = System.unique_integer([:positive])

    org =
      Organization.create!(%{name: "Owned #{n}", slug: "owned-#{n}"}, authorize?: false)

    Membership.create!(%{organization_id: org.id, user_id: user.id, role: :owner},
      authorize?: false
    )

    org
  end

  defp member_org!(user) do
    n = System.unique_integer([:positive])

    org =
      Organization.create!(%{name: "Member #{n}", slug: "member-#{n}"}, authorize?: false)

    Membership.create!(%{organization_id: org.id, user_id: user.id, role: :member},
      authorize?: false
    )

    org
  end

  describe "call/2" do
    test "the personal org is the only owned org for a fresh user, first" do
      user = AccountsFixtures.user!()
      personal = AccountsFixtures.personal_org!(user)

      assert {:ok, [org]} = Accounts.owned_orgs_for_user(user.id, actor: user)
      assert org.id == personal.id
    end

    test "mere memberships are not listed — ownership is the gate" do
      user = AccountsFixtures.user!()
      _personal = AccountsFixtures.personal_org!(user)
      _member_org = member_org!(user)

      assert {:ok, [only]} = Accounts.owned_orgs_for_user(user.id, actor: user)
      assert only.personal_owner_id == user.id
    end

    test "a second owned org rides along, the personal org stays first" do
      user = AccountsFixtures.user!()
      personal = AccountsFixtures.personal_org!(user)
      team = owned_org!(user)

      assert {:ok, [first, second] = orgs} = Accounts.owned_orgs_for_user(user.id, actor: user)
      assert length(orgs) == 2
      assert first.id == personal.id
      assert second.id == team.id
    end

    test "another actor's id yields nothing (the read policy filter-checks)" do
      user = AccountsFixtures.user!()
      _org = AccountsFixtures.personal_org!(user)
      stranger = AccountsFixtures.user!()

      assert {:ok, []} = Accounts.owned_orgs_for_user(user.id, actor: stranger)
    end

    test "no actor with the default authorize? is Forbidden (the policy gate)" do
      user = AccountsFixtures.user!()
      _org = AccountsFixtures.personal_org!(user)

      assert {:error, %Ash.Error.Forbidden{}} = Accounts.owned_orgs_for_user(user.id)
    end

    test "authorize?: false reads as the system caller (bootstrap posture)" do
      user = AccountsFixtures.user!()
      personal = AccountsFixtures.personal_org!(user)

      assert {:ok, [org]} = Accounts.owned_orgs_for_user(user.id, authorize?: false)
      assert org.id == personal.id
    end
  end
end
