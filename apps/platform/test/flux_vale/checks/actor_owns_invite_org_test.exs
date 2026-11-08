defmodule FluxVale.Checks.ActorOwnsInviteOrgTest do
  @moduledoc false

  # The invite/revoke gate's own resolution and arms; the action-level
  # behavior lives in the MembershipInvite/operation suites.

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Accounts.MembershipInvite
  alias FluxVale.Checks.ActorOwnsInviteOrg
  alias FluxVale.TestSupport.AccountsFixtures

  describe "describe/1" do
    test "names the gate" do
      assert ActorOwnsInviteOrg.describe([]) ==
               "actor is an owner of the invite's organization"
    end
  end

  describe "match?/3 — the subject's org resolution" do
    test "a create answers the org the write NAMES via the argument" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)

      subject =
        MembershipInvite
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:organization_id, org.id)
        |> Ash.Changeset.for_create(:create, %{email: "arg-named@fluxvale.test"},
          authorize?: false
        )

      assert ActorOwnsInviteOrg.match?(owner, %{subject: subject}, [])
      refute ActorOwnsInviteOrg.match?(AccountsFixtures.user!(), %{subject: subject}, [])
    end

    test "a create answers the org the write NAMES via the attribute — both intake shapes" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)

      subject =
        Ash.Changeset.for_create(
          MembershipInvite,
          :create,
          %{organization_id: org.id, email: "attr-named@fluxvale.test"},
          authorize?: false
        )

      assert ActorOwnsInviteOrg.match?(owner, %{subject: subject}, [])
    end

    test "a create naming nothing fails closed" do
      owner = AccountsFixtures.user!()
      AccountsFixtures.owned_org!(owner)

      subject =
        Ash.Changeset.for_create(MembershipInvite, :create, %{email: "unnamed@fluxvale.test"},
          authorize?: false
        )

      refute ActorOwnsInviteOrg.match?(owner, %{subject: subject}, [])
    end

    test "an anonymous actor fails closed" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)

      subject =
        Ash.Changeset.for_create(
          MembershipInvite,
          :create,
          %{organization_id: org.id, email: "anon@fluxvale.test"},
          authorize?: false
        )

      refute ActorOwnsInviteOrg.match?(nil, %{subject: subject}, [])
    end

    test "an update answers the ROW's org, freshly read" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      invitee = AccountsFixtures.user!()

      assert {:ok, invite} = invite!(owner, org, AccountsFixtures.primary_address!(invitee))

      subject = Ash.Changeset.for_update(invite, :revoke, %{}, authorize?: false)

      assert ActorOwnsInviteOrg.match?(owner, %{subject: subject}, [])
      refute ActorOwnsInviteOrg.match?(AccountsFixtures.user!(), %{subject: subject}, [])
    end

    test "a tampered REAL row still answers on the fresh row's org" do
      # The changeset claims an org the actor OWNS while the fresh row's
      # org is a stranger's — the gate must not care what the struct
      # claims (the ActorOwnsPaidOrg tamper probe).
      owner = AccountsFixtures.user!()
      owner_org = AccountsFixtures.owned_org!(owner)
      invitee = AccountsFixtures.user!()

      other_owner = AccountsFixtures.user!()
      other_org = AccountsFixtures.owned_org!(other_owner)

      assert {:ok, invite} =
               invite!(other_owner, other_org, AccountsFixtures.primary_address!(invitee))

      tampered =
        invite
        |> Ash.Changeset.for_update(:revoke, %{}, actor: owner)
        |> Ash.Changeset.force_change_attribute(:organization_id, owner_org.id)

      refute ActorOwnsInviteOrg.match?(owner, %{subject: tampered}, [])
      assert {:error, %Ash.Error.Forbidden{}} = Ash.update(tampered)

      # The refused tamper broke nothing real: the honest revoke works.
      assert {:ok, _revoked} = Accounts.revoke_invite(other_owner, invite)
    end

    test "a struct naming a vanished row fails closed" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      invitee = AccountsFixtures.user!()

      assert {:ok, invite} = invite!(owner, org, AccountsFixtures.primary_address!(invitee))
      Ash.destroy!(invite, authorize?: false)

      subject = Ash.Changeset.for_update(invite, :revoke, %{}, authorize?: false)

      refute ActorOwnsInviteOrg.match?(owner, %{subject: subject}, [])
    end

    test "an atomic changeset's placeholder data fails closed without raising" do
      org = AccountsFixtures.owned_org!(AccountsFixtures.user!())

      changeset =
        Ash.Changeset.for_update(
          %MembershipInvite{id: Ecto.UUID.generate(), organization_id: org.id},
          :revoke,
          %{},
          authorize?: false
        )

      atomic = %{changeset | data: %Ash.Changeset.OriginalDataNotAvailable{}}

      refute ActorOwnsInviteOrg.match?(nil, %{subject: atomic}, [])
    end

    test "a non-changeset subject fails closed" do
      refute ActorOwnsInviteOrg.match?(AccountsFixtures.user!(), %{subject: :not_a_changeset}, [])
    end
  end

  # The real policy path with NO actor: Forbidden, not a crash (the
  # nil-actor arm's live posture — the actorless call the doctrine
  # refuses).
  test "an actorless create is Forbidden" do
    org = AccountsFixtures.owned_org!(AccountsFixtures.user!())

    assert {:error, %Ash.Error.Forbidden{}} =
             MembershipInvite
             |> Ash.Changeset.new()
             |> Ash.Changeset.set_argument(:token_hash, arbitrary_hash())
             |> Ash.Changeset.for_create(
               :create,
               %{organization_id: org.id, email: "actorless@fluxvale.test"}
             )
             |> Ash.create()
  end

  # An arbitrary, unique digest for precondition rows.
  defp arbitrary_hash do
    n = System.unique_integer([:positive])
    seed = Integer.to_string(n)

    :sha256
    |> :crypto.hash(seed)
    |> Base.encode16(case: :lower)
  end

  # The invite rides the real owner seam (the gate under test is the
  # check, not the operation — the mail noise is the seam's own
  # property).
  defp invite!(owner, org, email) do
    Accounts.invite_member(owner, org, email)
  end
end
