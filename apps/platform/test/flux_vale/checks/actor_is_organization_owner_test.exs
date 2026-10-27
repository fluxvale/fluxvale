defmodule FluxVale.Checks.ActorIsOrganizationOwnerTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.TestSupport.AccountsFixtures

  describe "owner?/2" do
    test "an owner passes (record subject — the LiveView path)" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      assert ActorIsOrganizationOwner.owner?(user, org)
    end

    test "an owner passes (changeset subject — the policy path)" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      changeset = Ash.Changeset.for_update(org, :update, %{}, actor: user)

      assert ActorIsOrganizationOwner.owner?(user, changeset)
    end

    test "a :member does not — the role, not mere membership, is the gate" do
      org = AccountsFixtures.personal_org!(AccountsFixtures.user!())
      member = AccountsFixtures.user!()

      # Nothing in the system creates :member rows today (provisioning
      # makes only owners), so the precondition rides the create action
      # with authorize?: false — the sanctioned bootstrap posture.
      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      # The member can read the org (the read policy is member-scoped) —
      # the settings page is reachable; the update is what's gated.
      assert {:ok, _org} = Organization.get_by_slug(org.slug, actor: member)

      refute ActorIsOrganizationOwner.owner?(member, org)
    end

    test "a stranger does not" do
      org = AccountsFixtures.personal_org!(AccountsFixtures.user!())

      refute ActorIsOrganizationOwner.owner?(AccountsFixtures.user!(), org)
    end

    test "no actor never owns" do
      org = AccountsFixtures.personal_org!(AccountsFixtures.user!())

      refute ActorIsOrganizationOwner.owner?(nil, org)
      refute ActorIsOrganizationOwner.owner?(nil, %Ash.Changeset{})
    end
  end

  describe "describe/1" do
    test "states the question it answers" do
      assert ActorIsOrganizationOwner.describe([]) == "actor is an owner of the organization"
    end
  end
end
