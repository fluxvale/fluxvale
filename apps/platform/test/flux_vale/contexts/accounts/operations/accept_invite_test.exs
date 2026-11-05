defmodule FluxVale.Accounts.Operations.AcceptInviteTest do
  @moduledoc """
  The invitee seam (slice 4 of #408): raw token + signed-in user →
  membership with the invite's role, in the same transaction as the
  accepted_at stamp. The fences are pinned here: unknown token, wrong
  verified-primary email, terminal states, and the already-member
  pre-check each refuse without writing anything.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.MembershipInvite
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  describe "happy path" do
    test "accepting joins the org as :member and stamps accepted_at" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      invitee = AccountsFixtures.user!()

      assert {:ok, invite} = Accounts.invite_member(owner, org, invitee.email)
      raw = invited_token!(invitee.email)

      assert {:ok, accepted} = Accounts.accept_invite(raw, invitee)

      assert accepted.accepted_at
      assert accepted.role == :member

      # Exactly one membership, with the invite's role.
      assert [membership] = memberships(org, invitee)
      assert membership.role == :member
    end

    test "accept is single-fire — the second call refuses" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      invitee = AccountsFixtures.user!()

      assert {:ok, _invite} = Accounts.invite_member(owner, org, invitee.email)
      raw = invited_token!(invitee.email)

      assert {:ok, _accepted} = Accounts.accept_invite(raw, invitee)
      assert {:error, :already_accepted} = Accounts.accept_invite(raw, invitee)

      assert length(memberships(org, invitee)) == 1
    end

    test "the email match folds case" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      invitee = AccountsFixtures.user!()
      address = to_string(invitee.email)

      # The invite is addressed in a different case than the account's
      # address — citext on the row, downcase on the fence, one answer.
      addressed = String.upcase(address)

      assert {:ok, _invite} = Accounts.invite_member(owner, org, addressed)
      raw = invited_token!(addressed)

      assert {:ok, _accepted} = Accounts.accept_invite(raw, invitee)
    end
  end

  describe "refusals" do
    test "an unknown token refuses" do
      invitee = AccountsFixtures.user!()

      assert {:error, :unknown_token} =
               Accounts.accept_invite("no-such-token-material", invitee)
    end

    test "a signed-in user whose verified primary is not the invited address cannot join" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      invitee = AccountsFixtures.user!()
      stranger = AccountsFixtures.user!()

      assert {:ok, _invite} = Accounts.invite_member(owner, org, invitee.email)
      raw = invited_token!(invitee.email)

      assert {:error, :email_mismatch} = Accounts.accept_invite(raw, stranger)
      assert memberships(org, stranger) == []
    end

    test "an account with no verified primary row cannot join" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      invitee = AccountsFixtures.user!()

      assert {:ok, _invite} = Accounts.invite_member(owner, org, invitee.email)
      raw = invited_token!(invitee.email)

      # Ash.seed! — an account without its verified primary row is a
      # state the create mirror makes unproducible through actions
      # (the documented seed! exception, #285 T3). The invite row is
      # unaffected; only the account shape changes under the test.
      seed_email = to_string(invitee.email) <> ".seed"
      mirrorless = Ash.Seed.seed!(FluxVale.Identity.User, %{email: seed_email})

      assert {:error, :email_mismatch} = Accounts.accept_invite(raw, mirrorless)
      assert memberships(org, invitee) == []
    end

    test "an expired invite refuses" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      invitee = AccountsFixtures.user!()

      # Expiry is a state no action can produce (the expires_at default
      # is always future) — the whole row rides Ash.Seed with a chosen
      # token, the documented exception for exactly this shape (#23's
      # expired-token posture).
      raw = "expired-invite-token-material"
      past = DateTime.add(DateTime.utc_now(), -1, :minute)

      Ash.Seed.seed!(MembershipInvite, %{
        organization_id: org.id,
        email: invitee.email,
        token_hash: MembershipInvite.token_hash(raw),
        expires_at: past
      })

      assert {:error, :expired} = Accounts.accept_invite(raw, invitee)
      assert memberships(org, invitee) == []
    end

    test "a revoked invite refuses" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      invitee = AccountsFixtures.user!()

      assert {:ok, invite} = Accounts.invite_member(owner, org, invitee.email)
      raw = invited_token!(invitee.email)

      assert {:ok, _revoked} = Accounts.revoke_invite(owner, invite)

      assert {:error, :revoked} = Accounts.accept_invite(raw, invitee)
      assert memberships(org, invitee) == []
    end

    test "an invitee already in the org refuses before any write" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      invitee = AccountsFixtures.user!()

      assert {:ok, _invite} = Accounts.invite_member(owner, org, invitee.email)
      raw = invited_token!(invitee.email)

      # The invitee is a member of THIS org (the system path) while an
      # open invite for their address still stands.
      Membership.create!(
        %{organization_id: org.id, user_id: invitee.id, role: :member},
        authorize?: false
      )

      assert {:error, :already_member} = Accounts.accept_invite(raw, invitee)

      # The pre-check wrote nothing: one membership, and the invite
      # row stays open (no accepted_at stamp from a refused accept).
      assert length(memberships(org, invitee)) == 1
      assert {:ok, {:open, _invite}} = Accounts.resolve_invite(raw)
    end
  end

  # ---- helpers ---------------------------------------------------------

  # The raw token exists only in the emailed link (the seam's own
  # property) — tests read it out of the mailbox like an invitee would.
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
