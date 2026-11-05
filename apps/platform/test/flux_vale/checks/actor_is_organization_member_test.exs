defmodule FluxVale.Checks.ActorIsOrganizationMemberTest do
  @moduledoc false

  # #408's create fence: the named-org context is member-gated. The
  # check reads the grant row authorize-free (the ActorOrgWalletFunded
  # posture) and answers true/false — never the :unknown a filter check
  # degrades to when the actor cannot read a foreign org.

  use FluxVale.DataCase, async: true

  alias FluxVale.Checks.ActorIsOrganizationMember
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures

  describe "member?/2" do
    test "a grant counts; an org the user does not belong to does not" do
      {org, owner} = BillingFixtures.grant_free_org!()

      assert ActorIsOrganizationMember.member?(org.id, owner.id)
      refute ActorIsOrganizationMember.member?(org.id, Ecto.UUID.generate())
    end

    test "a nonexistent org has no members" do
      {_org, owner} = BillingFixtures.grant_free_org!()

      refute ActorIsOrganizationMember.member?(Ecto.UUID.generate(), owner.id)
    end
  end

  describe "the check itself" do
    test "describe/1 names the fence" do
      assert is_binary(ActorIsOrganizationMember.describe([]))
    end

    test "a create naming the actor's org passes; a foreign org fails" do
      actor = AccountsFixtures.user!()
      personal = AccountsFixtures.personal_org!(actor)
      {foreign, _foreign_owner} = BillingFixtures.grant_free_org!()

      # Built WITH the actor: the tenancy change runs and pins the named
      # org onto the attribute — the shape policies actually see.
      own =
        Ash.Changeset.for_create(Instance, :create, %{organization_id: personal.id}, actor: actor)

      foreign_subject =
        Ash.Changeset.for_create(Instance, :create, %{organization_id: foreign.id}, actor: actor)

      assert ActorIsOrganizationMember.match?(actor, %{subject: own}, [])
      refute ActorIsOrganizationMember.match?(actor, %{subject: foreign_subject}, [])
    end

    test "a create with no named org answers the personal default's membership" do
      actor = AccountsFixtures.user!()
      AccountsFixtures.personal_org!(actor)

      # With an actor the tenancy change always pins an org before
      # policies run — here the personal org, whose membership holds.
      subject = Ash.Changeset.for_create(Instance, :create, %{}, actor: actor)

      assert ActorIsOrganizationMember.match?(actor, %{subject: subject}, [])
    end

    test "a changeset that named no org fails closed" do
      actor = AccountsFixtures.user!()
      AccountsFixtures.personal_org!(actor)

      # Built WITHOUT an actor: the tenancy change's no-actor clause
      # leaves the attribute unset — the check sees no named org and
      # answers false, never a guess.
      subject = Ash.Changeset.for_create(Instance, :create, %{}, authorize?: false)

      refute ActorIsOrganizationMember.match?(actor, %{subject: subject}, [])
    end

    test "a non-changeset subject fails closed" do
      actor = AccountsFixtures.user!()
      personal = AccountsFixtures.personal_org!(actor)

      refute ActorIsOrganizationMember.match?(actor, %{subject: personal}, [])
    end

    test "no actor fails closed" do
      actor = AccountsFixtures.user!()
      personal = AccountsFixtures.personal_org!(actor)

      subject =
        Ash.Changeset.for_create(Instance, :create, %{organization_id: personal.id}, actor: actor)

      refute ActorIsOrganizationMember.match?(nil, %{subject: subject}, [])
    end
  end
end
