defmodule FluxVale.Accounts.Operations.InviteMemberTest do
  @moduledoc """
  The owner seam of the invitation flow (slice 4 of #408): org + email
  → an OPEN :member invite plus the mail carrying the raw token. The
  token never comes back through the return — the only place tests (and
  invitees) can read it is the emailed link, which is the property that
  makes the row's hash-only storage honest.
  """

  use FluxVale.DataCase, async: true
  use Mimic

  setup :verify_on_exit!

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.MembershipInvite
  alias FluxVale.Mailer
  alias FluxVale.TestSupport.AccountsFixtures

  describe "happy path" do
    test "creates an open :member invite and mails the link" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)

      assert {:ok, invite} = Accounts.invite_member(owner, org, "newmate@fluxvale.test")

      assert invite.role == :member
      assert Ash.load!(invite, :state, authorize?: false).state == :open
      assert to_string(invite.email) == "newmate@fluxvale.test"

      # The mail is the only place the raw token exists — pull it out
      # and pin the stored digest to exactly that value.
      assert {:ok, mail} = mailbox_invite_mail("newmate@fluxvale.test")
      raw = token_from_body!(mail)
      digest = MembershipInvite.token_hash(raw)

      assert {:ok, stored} = MembershipInvite.get_by_token_hash(digest, authorize?: false)

      assert stored.id == invite.id
      refute stored.token_hash == raw
    end

    test "the mail names the org and the accept link" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)

      assert {:ok, _invite} = Accounts.invite_member(owner, org, "copycheck@fluxvale.test")

      assert {:ok, mail} = mailbox_invite_mail("copycheck@fluxvale.test")

      assert mail.subject == "You are invited to #{org.name}"
      assert mail.text_body =~ "/invitations/accept?token="
      # The copy's style rule: plain sentences, no em-dashes, no semicolons.
      refute mail.text_body =~ "—"
      refute mail.text_body =~ ";"
    end
  end

  describe "one open invite per (org, email)" do
    test "a duplicate open invite is refused with the distinct answer" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)

      assert {:ok, _invite} = Accounts.invite_member(owner, org, "twice@fluxvale.test")

      assert {:error, :duplicate_invite} =
               Accounts.invite_member(owner, org, "twice@fluxvale.test")
    end

    test "citext folds the case in the duplicate check" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)

      assert {:ok, _invite} = Accounts.invite_member(owner, org, "fold@fluxvale.test")

      assert {:error, :duplicate_invite} =
               Accounts.invite_member(owner, org, "FOLD@fluxvale.test")
    end

    test "another org's open invite does not block this org" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      other_org = AccountsFixtures.owned_org!(owner)

      assert {:ok, _invite} = Accounts.invite_member(owner, org, "shared@fluxvale.test")

      assert {:ok, _invite} =
               Accounts.invite_member(owner, other_org, "shared@fluxvale.test")
    end

    test "a revoked invite frees the address for a re-invite" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)

      assert {:ok, invite} = Accounts.invite_member(owner, org, "reinvite@fluxvale.test")
      assert {:ok, _revoked} = Accounts.revoke_invite(owner, invite)

      assert {:ok, _fresh} = Accounts.invite_member(owner, org, "reinvite@fluxvale.test")
    end

    test "a re-invite over an expired row supersedes it and lands fresh" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      invitee = AccountsFixtures.user!()

      # An expired row holds the address at the index (its predicate
      # cannot carry now()) — a state no action can produce, so the
      # stale row rides Ash.Seed (the documented exception).
      past = DateTime.add(DateTime.utc_now(), -1, :minute)

      stale =
        Ash.Seed.seed!(MembershipInvite, %{
          organization_id: org.id,
          email: invitee.email,
          token_hash: stale_hash(),
          expires_at: past
        })

      assert {:ok, fresh} = Accounts.invite_member(owner, org, invitee.email)

      assert {:ok, mail} = mailbox_invite_mail(to_string(invitee.email))
      raw = token_from_body!(mail)

      # The fresh row answers the token; the stale row is retired
      # (revoked) — history, not a trap.
      assert {:ok, {:open, resolved}} = Accounts.resolve_invite(raw)
      assert resolved.id == fresh.id

      assert %{revoked_at: stamped} = Ash.load!(stale, :revoked_at, authorize?: false)
      assert stamped
    end

    test "a refused caller mutates nothing — an expired row is not retired by a refusal" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      member = AccountsFixtures.user!()
      invitee = AccountsFixtures.user!()

      seed_member!(org, member)

      # An expired row holds the address (a state no action can
      # produce — Ash.Seed, the documented exception).
      stale =
        Ash.Seed.seed!(MembershipInvite, %{
          organization_id: org.id,
          email: invitee.email,
          token_hash: stale_hash(),
          expires_at: DateTime.add(DateTime.utc_now(), -1, :minute)
        })

      # The member's call is Forbidden — and stays a pure refusal: the
      # supersede arm never runs on Forbidden, so the stale row's
      # revoked_at stays nil (the probe-proof for the P2 ordering).
      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.invite_member(member, org, invitee.email)

      assert %{revoked_at: nil} = Ash.load!(stale, :revoked_at, authorize?: false)
    end

    test "a malformed address is refused before anything is stored or sent" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)

      assert {:error, :invalid_email} = Accounts.invite_member(owner, org, "not-an-address")

      # Nothing landed and nothing was sent.
      refute_received {:email, _}
    end
  end

  describe "policies" do
    test "a member who is not the owner is refused" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      member = AccountsFixtures.user!()

      seed_member!(org, member)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.invite_member(member, org, "member-invite@fluxvale.test")
    end

    test "a stranger to the org is refused" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      stranger = AccountsFixtures.user!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.invite_member(stranger, org, "stranger-invite@fluxvale.test")
    end
  end

  describe "mail failure" do
    test "a delivery failure never fails the invite — the row is the truth" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)

      stub(Mailer, :deliver_org_invitation, fn _to, _org_name, _url ->
        {:error, :gateway_down}
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, invite} = Accounts.invite_member(owner, org, "bounced@fluxvale.test")

          assert Ash.load!(invite, :state, authorize?: false).state == :open
        end)

      assert log =~ "Invite mail failed"
      assert log =~ ":gateway_down"
    end
  end

  # ---- helpers ---------------------------------------------------------

  # The mail rides Swoosh's test adapter into the test process's
  # mailbox; the invite seam's delivery is the only source.
  defp mailbox_invite_mail(address) do
    assert_receive {:email, %Swoosh.Email{to: [{_display, ^address}]} = mail}, 1000
    {:ok, mail}
  end

  defp token_from_body!(mail) do
    assert [token] =
             Regex.run(~r{/invitations/accept\?token=([A-Za-z0-9_-]+)}, mail.text_body,
               capture: :all_but_first
             )

    token
  end

  defp seed_member!(org, user) do
    Membership.create!(
      %{organization_id: org.id, user_id: user.id, role: :member},
      authorize?: false
    )
  end

  # An arbitrary, unique digest for precondition rows — the value's
  # shape is what matters (64-hex), not what it hashes.
  defp stale_hash do
    n = System.unique_integer([:positive])
    seed = Integer.to_string(n)

    :sha256
    |> :crypto.hash(seed)
    |> Base.encode16(case: :lower)
  end
end
