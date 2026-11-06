defmodule FluxVale.Identity.Operations.AcceptInvitationTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.AuthCodeHelpers
  import FluxVale.TestSupport.UserInviteHelpers

  alias FluxVale.Accounts.Membership
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Wallet
  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Ops.AccessRule
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.Telemetry
  require Ash.Query

  setup do
    %{address: "accept-#{System.unique_integer()}@partner.example"}
  end

  defp users_with_email(address) do
    User
    |> Ash.Query.filter(email == ^address)
    |> Ash.read!(authorize?: false)
  end

  defp rows_for(address) do
    UserEmail
    |> Ash.Query.filter(address == ^address)
    |> Ash.read!(authorize?: false)
  end

  defp reloaded(user_id) do
    User
    |> Ash.Query.filter(id == ^user_id)
    |> Ash.Query.load(:invite_state)
    |> Ash.read_one!(authorize?: false)
  end

  describe "call/1 — the happy path" do
    test "stamps acceptance, bootstraps, writes the verified primary row, and mints a session", %{
      address: address
    } do
      {invited, raw} = invite_user!(address)
      event = Identity.signup_event()
      Telemetry.capture_events([event])

      assert {:ok, user, token} = Identity.accept_invitation(raw)

      assert user.id == invited.id
      assert user.invite_accepted_at
      assert user.username
      assert is_binary(token) and token != ""

      # acceptance is the inbox proof: the mirror row lands VERIFIED and
      # PRIMARY
      assert [%{user_id: owner_id, verified_at: verified, is_primary: true}] = rows_for(address)
      assert owner_id == user.id
      refute is_nil(verified)

      # the same first-login bootstrap a JIT signup runs: personal org
      # (creator = owner), welcome-credit ledger entry
      org = AccountsFixtures.personal_org!(user)

      assert [%{role: :owner}] =
               Membership
               |> Ash.Query.filter(user_id == ^user.id and organization_id == ^org.id)
               |> Ash.read!(authorize?: false)

      wallet = Wallet.get_by_organization!(org.id, authorize?: false)

      assert [%{type: :credit, reason: :welcome}] =
               LedgerEntry
               |> Ash.Query.filter(wallet_id == ^wallet.id and reason == :welcome)
               |> Ash.read!(authorize?: false)

      assert_receive {:telemetry_event, ^event, %{count: 1}, %{}}
    end

    test "the link works exactly once — the second call refuses and nothing moves", %{
      address: address
    } do
      {_invited, raw} = invite_user!(address)
      {:ok, user, _token} = Identity.accept_invitation(raw)
      stamp = user.invite_accepted_at

      assert {:error, :already_accepted} = Identity.accept_invitation(raw)

      reloaded = reloaded(user.id)
      assert reloaded.invite_accepted_at == stamp
      assert reloaded.invite_state == :accepted
    end
  end

  describe "call/1 — the refusals" do
    test "an unknown token refuses" do
      assert {:error, :unknown_token} = Identity.accept_invitation("no-such-token")
    end

    test "a withdrawn invite refuses", %{address: address} do
      {invited, raw} = invite_user!(address)
      withdraw_invite!(invited)

      assert {:error, :withdrawn} = Identity.accept_invitation(raw)
    end

    test "an expired invite refuses", %{address: address} do
      # actions cannot backdate the window — seed! is the sanctioned bypass
      expired_invited_user!(address)

      assert {:error, :expired} = Identity.accept_invitation("expired-raw")
    end

    test "a hash with no invite stamps is an unknown token", %{address: address} do
      # structurally unreachable through actions (the hash is only ever
      # written alongside invited_at) — seed! is the sanctioned bypass
      # for the hand-built shape
      Ash.Seed.seed!(User, %{email: address, invite_token_hash: User.token_hash("orphan")})

      assert {:error, :unknown_token} = Identity.accept_invitation("orphan")
    end

    test "an AccessRule denial stops the session — the consume already committed", %{
      address: address
    } do
      # any row closes the allowlist; this one admits another address
      AccessRule.create!(%{email: "someone-else@partner.example"}, authorize?: false)
      {_invited, raw} = invite_user!(address)

      assert {:error, :not_allowed} = Identity.accept_invitation(raw)

      # the gate rides the session mint (the code flow's severing
      # posture): the acceptance stamp stands, only the session is
      # withheld
      [stamped] = users_with_email(address)
      assert stamped.invite_accepted_at
    end
  end

  describe "call/1 — address conflicts on the mirror insert" do
    test "a pending third-party claim does not wedge acceptance", %{address: address} do
      # a claim confers no proof (the AddEmail posture), but
      # unique_address is global — before the supersede this collision
      # rolled the acceptance back with the terminal refusal copy
      claimant =
        User.create!("claimant-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

      {:ok, _claim} = Identity.add_email(claimant, address)
      _claim_code = mailbox_code()

      {invited, raw} = invite_user!(address)

      assert {:ok, accepted, _jwt} = Identity.accept_invitation(raw)
      assert accepted.invite_accepted_at

      # the proof-less claim is gone; the address's one row is the
      # mirror row acceptance wrote for the invited account
      assert [%{user_id: owner_id}] = rows_for(address)
      assert owner_id == invited.id
    end

    test "a verified conflicting row refuses honestly — the state stands unconsumed", %{
      address: address
    } do
      # someone proved this inbox from a DIFFERENT account after the
      # invite was minted: a genuine ownership conflict the admin must
      # resolve, not a wedge — nothing is consumed, the refusal is one
      # sentence
      {invited, raw} = invite_user!(address)

      holder =
        User.create!("holder-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

      {:ok, claim} = Identity.add_email(holder, address)
      {:ok, _verified} = Identity.verify_email(holder, claim.id, mailbox_code())

      assert {:error, :unavailable} = Identity.accept_invitation(raw)

      unconsumed = reloaded(invited.id)
      assert unconsumed.invite_state == :pending
      refute unconsumed.invite_accepted_at
    end
  end
end
