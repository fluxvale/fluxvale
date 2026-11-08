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

  # #287: any row on the address resolves its owner (the users table
  # carries no address).
  defp users_with_email(address) do
    case User.get_by_address(address, authorize?: false) do
      {:ok, user} -> [user]
      {:error, _not_found} -> []
    end
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
      Ash.Seed.seed!(User, %{
        username: "orphan-#{System.unique_integer([:positive])}",
        invite_token_hash: User.token_hash("orphan")
      })

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

  describe "call/1 — the reserved address (#287)" do
    test "a stranger cannot claim the invited address — the reservation wins", %{address: address} do
      # #287's first-verified-wins ruling: the invitation RESERVES its
      # address from :invite (a pending row; unique_address is global
      # and pending-inclusive). The mirror-era steal — a stranger
      # claims, verifies, and wedges acceptance into :unavailable — is
      # structurally gone: the claim is refused at :add, honestly, at
      # claim time instead of wedging after a verified steal.
      {invited, _raw} = invite_user!(address)

      stranger =
        User.create!("stranger-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} = Identity.add_email(stranger, address)

      # the reservation stands, untouched by the refused claim
      assert [%{user_id: owner_id, verified_at: nil}] = rows_for(address)
      assert owner_id == invited.id
    end
  end
end
