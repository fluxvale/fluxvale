defmodule FluxVale.Accounts.PaperTrailTest do
  @moduledoc false

  # The audit-trail proof on Accounts (#645, the plan's A2-S3 slice):
  # org creation, role flips, and the invite lifecycle attribute to
  # their owner actors, and the invite's token hash redacts everywhere
  # including the unchanged-marker case (decision one, ADR-0048).
  # Mirrors the Billing suite (the A2-S2 exemplar).

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.MembershipInvite
  alias FluxVale.Accounts.Organization
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  defp versions!(version_module, source_id) do
    version_module
    |> Ash.Query.filter(version_source_id == ^source_id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  describe "orgs and memberships attribute to their actors" do
    test "a create_with_owner versions the creating user" do
      user = AccountsFixtures.user!()
      n = System.unique_integer([:positive])

      org =
        Organization
        |> Ash.Changeset.for_create(
          :create_with_owner,
          %{name: "PT Org #{n}", slug: "pt-org-#{n}"},
          actor: user
        )
        |> Ash.create!()

      [version] = versions!(Organization.Version, org.id)

      assert version.version_action_name == :create_with_owner
      assert version.version_action_type == :create
      assert version.user_id == user.id
      assert version.actor_label == user.username

      # The owner membership the change appends is versioned too.
      membership =
        Membership
        |> Ash.Query.filter(organization_id == ^org.id and user_id == ^user.id)
        |> Ash.read!(authorize?: false)
        |> List.first()

      assert [_membership_version] = versions!(Membership.Version, membership.id)
    end

    test "a set_role versions the owner actor" do
      owner = AccountsFixtures.user!()
      {_org, owner_membership} = org_and_owner_membership!(owner)
      member = AccountsFixtures.user!()

      # Precondition via the action (authorize?: false, the repo
      # convention): the promoted member joins through :create.
      membership =
        Membership.create!(
          %{organization_id: owner_membership.organization_id, user_id: member.id, role: :member},
          authorize?: false
        )

      membership
      |> Ash.Changeset.for_update(:set_role, %{role: :owner}, actor: owner)
      |> Ash.update!()

      [create_version, promote_version] = versions!(Membership.Version, membership.id)

      assert promote_version.version_action_name == :set_role
      assert promote_version.user_id == owner.id
      assert promote_version.actor_label == owner.username

      # The precondition create rides authorize?: false with no actor —
      # its version row is honestly system-attributed.
      assert is_nil(create_version.user_id)
    end
  end

  describe "the invite lifecycle attributes and redacts" do
    test "an invite create and revoke version the owner, the hash redacted" do
      owner = AccountsFixtures.user!()
      {org, _owner_membership} = org_and_owner_membership!(owner)

      address = "pt-member-invite-#{System.unique_integer([:positive])}@fluxvale.test"
      {:ok, invite} = FluxVale.Accounts.invite_member(owner, org, address)
      {:ok, _revoked} = FluxVale.Accounts.revoke_invite(owner, invite)

      [create_version, revoke_version] = versions!(MembershipInvite.Version, invite.id)

      assert create_version.version_action_name == :create
      assert create_version.user_id == owner.id
      assert create_version.actor_label == owner.username

      # Decision one: the hash reads REDACTED in the create's changes,
      # and no raw value rides the inputs.
      assert create_version.changes["token_hash"] == "REDACTED"
      assert Map.get(create_version.version_action_inputs, "token_hash") in [nil, "REDACTED"]

      # The invited address is PII: the flagged attribute reads
      # REDACTED in BOTH changes and inputs (ADR-0048).
      assert create_version.changes["email"] == "REDACTED"
      assert create_version.version_action_inputs["email"] == "REDACTED"

      assert revoke_version.version_action_name == :revoke
      assert revoke_version.user_id == owner.id

      # The revoke writes no hash — the REDACTED marker rides anyway
      # (the unchanged-marker case, pinned).
      assert revoke_version.changes["token_hash"] == "REDACTED"
      assert revoke_version.changes["revoked_at"]
    end
  end

  # The owned-org fixture returns the org; the owner's membership rides
  # its own read.
  defp org_and_owner_membership!(owner) do
    org = AccountsFixtures.owned_org!(owner)

    membership =
      Membership
      |> Ash.Query.filter(organization_id == ^org.id and user_id == ^owner.id)
      |> Ash.read!(authorize?: false)
      |> List.first()

    {org, membership}
  end
end
