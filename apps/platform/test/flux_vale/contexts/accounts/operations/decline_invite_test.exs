defmodule FluxVale.Accounts.Operations.DeclineInviteTest do
  @moduledoc """
  The invitee's no (slice 4 of #408): the raw token retires the invite
  (revoked_at stamped) and no membership is ever written. Terminal
  states refuse — nothing may retire an invite something already
  happened to.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  test "declining stamps revoked_at and writes no membership" do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)
    invitee = AccountsFixtures.user!()

    assert {:ok, _invite} =
             Accounts.invite_member(owner, org, AccountsFixtures.primary_address!(invitee))

    raw = invited_token!(AccountsFixtures.primary_address!(invitee))

    assert {:ok, declined} = Accounts.decline_invite(raw)

    assert declined.revoked_at
    refute declined.accepted_at
    assert memberships(org, invitee) == []
  end

  test "a declined invite cannot accept afterwards" do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)
    invitee = AccountsFixtures.user!()

    assert {:ok, _invite} =
             Accounts.invite_member(owner, org, AccountsFixtures.primary_address!(invitee))

    raw = invited_token!(AccountsFixtures.primary_address!(invitee))

    assert {:ok, _declined} = Accounts.decline_invite(raw)
    assert {:error, :revoked} = Accounts.accept_invite(raw, invitee)
  end

  test "declining twice refuses — the row is no longer open" do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)
    invitee = AccountsFixtures.user!()

    assert {:ok, _invite} =
             Accounts.invite_member(owner, org, AccountsFixtures.primary_address!(invitee))

    raw = invited_token!(AccountsFixtures.primary_address!(invitee))

    assert {:ok, _declined} = Accounts.decline_invite(raw)
    assert {:error, :not_open} = Accounts.decline_invite(raw)
  end

  test "an accepted invite cannot be declined" do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)
    invitee = AccountsFixtures.user!()

    assert {:ok, _invite} =
             Accounts.invite_member(owner, org, AccountsFixtures.primary_address!(invitee))

    raw = invited_token!(AccountsFixtures.primary_address!(invitee))

    assert {:ok, _accepted} = Accounts.accept_invite(raw, invitee)
    assert {:error, :not_open} = Accounts.decline_invite(raw)

    # The membership rides.
    assert length(memberships(org, invitee)) == 1
  end

  test "an unknown token refuses" do
    assert {:error, :unknown_token} = Accounts.decline_invite("no-such-token-material")
  end

  defp invited_token!(address) do
    address = to_string(address)
    assert_receive {:email, %Swoosh.Email{to: [{_, ^address}], text_body: body}}, 1000

    [token] =
      Regex.run(~r{/invitations/accept\?token=([A-Za-z0-9_-]+)}, body, capture: :all_but_first)

    token
  end

  defp memberships(org, user) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(organization_id == ^org.id and user_id == ^user.id)
    |> Ash.read!(authorize?: false)
  end
end
