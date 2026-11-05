defmodule FluxVale.Accounts.Operations.RevokeInviteTest do
  @moduledoc """
  The owner's retirement seam (slice 4 of #408): revoking stamps
  revoked_at idempotently and frees the address. The owner policy is
  the gate — pinned here alongside the working owner path.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.TestSupport.AccountsFixtures

  test "the owner revokes — revoked_at stamped, the invite leaves :open" do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)
    invitee = AccountsFixtures.user!()

    assert {:ok, invite} = Accounts.invite_member(owner, org, invitee.email)

    assert {:ok, revoked} = Accounts.revoke_invite(owner, invite)

    assert revoked.revoked_at
    assert Ash.load!(revoked, :state, authorize?: false).state == :revoked
  end

  test "revoking keeps a pre-existing stamp — the idempotence contract" do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)
    invitee = AccountsFixtures.user!()

    assert {:ok, invite} = Accounts.invite_member(owner, org, invitee.email)

    # A backdated revoked_at is a state no action can produce (the
    # change always stamps now) — seed! territory, the documented
    # exception. It pins the KEEP arm deterministically: second-probe
    # stamps truncated to the second would compare equal by accident.
    seeded_stamp = ~U[2024-06-01 12:00:00Z]

    seeded =
      Ash.Seed.seed!(FluxVale.Accounts.MembershipInvite, %{
        organization_id: org.id,
        email: invitee.email,
        token_hash: String.duplicate("b", 64),
        revoked_at: seeded_stamp,
        expires_at: invite.expires_at
      })

    assert {:ok, revoked} = Accounts.revoke_invite(owner, seeded)
    assert revoked.revoked_at == seeded_stamp
  end

  test "a stale struct (revoked elsewhere) keeps the original stamp" do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)
    invitee = AccountsFixtures.user!()

    # The DB row carries a backdated stamp (a state no action can
    # produce — Ash.Seed, the documented exception); the struct in hand
    # predates it (revoked_at nil in memory) — exactly the
    # another-tab-already-revoked shape members_test drives from the
    # page. The keep decision must read the ROW, not the struct.
    seeded_stamp = ~U[2024-06-01 12:00:00Z]

    row =
      Ash.Seed.seed!(FluxVale.Accounts.MembershipInvite, %{
        organization_id: org.id,
        email: invitee.email,
        token_hash: String.duplicate("e", 64),
        revoked_at: seeded_stamp,
        expires_at: DateTime.add(DateTime.utc_now(), 1, :hour)
      })

    stale_struct = %{row | revoked_at: nil}

    assert {:ok, revoked} = Accounts.revoke_invite(owner, stale_struct)
    assert revoked.revoked_at == seeded_stamp
  end

  test "a member who is not the owner cannot revoke" do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)
    member = AccountsFixtures.user!()
    invitee = AccountsFixtures.user!()

    Membership.create!(
      %{organization_id: org.id, user_id: member.id, role: :member},
      authorize?: false
    )

    assert {:ok, invite} = Accounts.invite_member(owner, org, invitee.email)

    assert {:error, %Ash.Error.Forbidden{}} = Accounts.revoke_invite(member, invite)
  end
end
