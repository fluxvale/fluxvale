defmodule FluxVale.Checks.ActorOwnsMembershipOrgTest do
  @moduledoc false

  # The lifecycle gate's own resolution and arms; the action-level
  # behavior lives in the Membership lifecycle and operation suites.

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts.Membership
  alias FluxVale.Checks.ActorOwnsMembershipOrg
  alias FluxVale.TestSupport.AccountsFixtures

  describe "describe/1" do
    test "names the gate" do
      assert ActorOwnsMembershipOrg.describe([]) ==
               "actor is an owner of the membership's organization"
    end
  end

  describe "match?/3 — the subject's org resolution" do
    test "an update answers the ROW's org, freshly read" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      member = AccountsFixtures.user!()
      membership = seed_member!(org, member)

      subject =
        Ash.Changeset.for_update(membership, :set_role, %{role: :owner}, authorize?: false)

      assert ActorOwnsMembershipOrg.match?(owner, %{subject: subject}, [])
      refute ActorOwnsMembershipOrg.match?(member, %{subject: subject}, [])
    end

    test "a tampered REAL row still answers on the fresh row's org" do
      # The changeset claims an org the actor OWNS while the fresh row's
      # org is a stranger's — the gate must not care what the struct
      # claims (the ActorOwnsPaidOrg tamper probe).
      owner = AccountsFixtures.user!()
      owner_org = AccountsFixtures.owned_org!(owner)

      other_owner = AccountsFixtures.user!()
      other_org = AccountsFixtures.owned_org!(other_owner)
      member = AccountsFixtures.user!()
      membership = seed_member!(other_org, member)

      tampered =
        membership
        |> Ash.Changeset.for_update(:set_role, %{role: :owner}, actor: owner)
        |> Ash.Changeset.force_change_attribute(:organization_id, owner_org.id)

      refute ActorOwnsMembershipOrg.match?(owner, %{subject: tampered}, [])
      assert {:error, %Ash.Error.Forbidden{}} = Ash.update(tampered)

      # The refused tamper broke nothing real: the honest promote works.
      assert {:ok, _promoted} =
               Membership.set_role(membership, %{role: :owner}, actor: other_owner)
    end

    test "a struct naming a vanished row fails closed" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      member = AccountsFixtures.user!()
      membership = seed_member!(org, member)

      Ash.destroy!(membership, authorize?: false)

      subject =
        Ash.Changeset.for_update(membership, :set_role, %{role: :owner}, authorize?: false)

      refute ActorOwnsMembershipOrg.match?(owner, %{subject: subject}, [])
    end

    test "an atomic changeset's placeholder data fails closed without raising" do
      org = AccountsFixtures.owned_org!(AccountsFixtures.user!())
      member = AccountsFixtures.user!()
      membership = seed_member!(org, member)

      changeset =
        Ash.Changeset.for_update(
          %Membership{id: membership.id, organization_id: org.id},
          :set_role,
          %{role: :owner},
          authorize?: false
        )

      atomic = %{changeset | data: %Ash.Changeset.OriginalDataNotAvailable{}}

      refute ActorOwnsMembershipOrg.match?(nil, %{subject: atomic}, [])
    end

    test "a non-changeset subject fails closed" do
      refute ActorOwnsMembershipOrg.match?(
               AccountsFixtures.user!(),
               %{subject: :not_a_changeset},
               []
             )
    end
  end

  # The real policy path with NO actor: Forbidden, not a crash (the
  # nil-actor arm's live posture — the actorless call the doctrine
  # refuses).
  test "an actorless set_role is Forbidden" do
    org = AccountsFixtures.owned_org!(AccountsFixtures.user!())
    membership = seed_member!(org, AccountsFixtures.user!())

    assert {:error, %Ash.Error.Forbidden{}} =
             Membership.set_role(membership, %{role: :owner})
  end

  # Nothing outside the invite accept flow creates :member rows —
  # preconditions ride the create action with authorize?: false (the
  # bootstrap posture, mirroring seeds).
  defp seed_member!(org, user) do
    Membership.create!(%{organization_id: org.id, user_id: user.id, role: :member},
      authorize?: false
    )
  end
end
