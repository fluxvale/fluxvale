defmodule FluxVale.Accounts.Operations.ResolveInviteTest do
  @moduledoc """
  The token path's read seam (slice 4 of #408): a raw token resolves to
  `{:open, invite}` or one terminal word — the whole state axis the
  accept page renders from. The org rides the open arm (the page needs
  its name without a second read).
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Accounts.MembershipInvite
  alias FluxVale.TestSupport.AccountsFixtures

  test "a live invite resolves open, with the org loaded" do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)

    assert {:ok, _invite} = Accounts.invite_member(owner, org, "resolver@fluxvale.test")
    raw = invited_token!("resolver@fluxvale.test")

    assert {:ok, {:open, invite}} = Accounts.resolve_invite(raw)
    assert invite.organization.id == org.id
    assert invite.organization.name == org.name
  end

  test "an accepted invite resolves terminal" do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)
    invitee = AccountsFixtures.user!()

    assert {:ok, _invite} =
             Accounts.invite_member(owner, org, AccountsFixtures.primary_address!(invitee))

    raw = invited_token!(AccountsFixtures.primary_address!(invitee))

    assert {:ok, _accepted} = Accounts.accept_invite(raw, invitee)
    assert {:ok, :accepted} = Accounts.resolve_invite(raw)
  end

  test "a revoked invite resolves terminal" do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)
    invitee = AccountsFixtures.user!()

    assert {:ok, invite} =
             Accounts.invite_member(owner, org, AccountsFixtures.primary_address!(invitee))

    raw = invited_token!(AccountsFixtures.primary_address!(invitee))

    assert {:ok, _revoked} = Accounts.revoke_invite(owner, invite)
    assert {:ok, :revoked} = Accounts.resolve_invite(raw)
  end

  test "an expired invite resolves terminal" do
    org = AccountsFixtures.owned_org!(AccountsFixtures.user!())

    # Expiry is a state no action can produce (the expires_at default
    # is always future) — the documented seed! exception.
    raw = "expired-resolver-token-material"

    Ash.Seed.seed!(MembershipInvite, %{
      organization_id: org.id,
      email: "expired-resolver@fluxvale.test",
      token_hash: MembershipInvite.token_hash(raw),
      expires_at: DateTime.add(DateTime.utc_now(), -1, :minute)
    })

    assert {:ok, :expired} = Accounts.resolve_invite(raw)
  end

  test "an unknown token refuses" do
    assert {:error, :unknown_token} = Accounts.resolve_invite("no-such-token-material")
  end

  test "a missing token (empty query param) reads as unknown, not a crash" do
    assert {:error, :unknown_token} = Accounts.resolve_invite(nil)
  end

  defp invited_token!(address) do
    address = to_string(address)
    assert_receive {:email, %Swoosh.Email{to: [{_, ^address}], text_body: body}}, 1000

    [token] =
      Regex.run(~r{/invitations/accept\?token=([A-Za-z0-9_-]+)}, body, capture: :all_but_first)

    token
  end
end
