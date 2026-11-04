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

  test "revoking twice keeps the original stamp" do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)
    invitee = AccountsFixtures.user!()

    assert {:ok, invite} = Accounts.invite_member(owner, org, invitee.email)

    assert {:ok, first} = Accounts.revoke_invite(owner, invite)
    assert {:ok, second} = Accounts.revoke_invite(owner, invite)

    assert DateTime.compare(second.revoked_at, first.revoked_at) == :eq
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
