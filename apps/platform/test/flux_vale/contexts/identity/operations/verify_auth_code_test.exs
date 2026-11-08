defmodule FluxVale.Identity.Operations.VerifyAuthCodeTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.AuthCodeHelpers
  import FluxVale.TestSupport.UserInviteHelpers

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Ops.AccessRule
  alias FluxVale.TestSupport.Telemetry
  require Ash.Query

  setup do
    email = "verify-code-#{System.unique_integer()}@fluxvale.com"
    %{email: email}
  end

  defp rows_for(address) do
    UserEmail
    |> Ash.Query.filter(address == ^address)
    |> Ash.read!(authorize?: false)
  end

  # #287: any row on the address resolves its owner (the users table
  # carries no address).
  defp users_with_email(email) do
    case User.get_by_address(email, authorize?: false) do
      {:ok, user} -> [user]
      {:error, _not_found} -> []
    end
  end

  describe "call/2" do
    test "a JIT signup fires the signup counter — the {:ok, user} arm only", %{email: email} do
      Telemetry.capture_events([[:flux_vale, :identity, :signup]])

      :ok = Identity.request_auth_code(email)

      assert {:ok, _user, _token} = Identity.verify_auth_code(email, mailbox_code())

      assert_receive {:telemetry_event, [:flux_vale, :identity, :signup], %{count: 1}, %{}}
    end

    test "wrong code increments attempts and stays verifiable", %{email: email} do
      :ok = Identity.request_auth_code(email)
      code = mailbox_code()

      assert {:error, :wrong_code} = Identity.verify_auth_code(email, "00000")

      assert [%{attempts: 1}] = active_codes(email)
      assert {:ok, _user_ok, _token_ok} = Identity.verify_auth_code(email, code)
    end

    test "locks out after five wrong attempts (the cap is the backoff)", %{
      email: email
    } do
      :ok = Identity.request_auth_code(email)
      _code = mailbox_code()

      for _attempt <- 1..5,
          do: assert({:error, :wrong_code} = Identity.verify_auth_code(email, "000000"))

      # The atomic cap guard makes the boundary race-safe: the 6th guess
      # is refused by the update itself, not just the pre-check (CWE-307)
      assert {:error, :locked_out} = Identity.verify_auth_code(email, "000000")
    end

    test "the atomic cap guard itself refuses past the limit (CWE-307)", %{
      email: email
    } do
      :ok = Identity.request_auth_code(email)
      _code = mailbox_code()
      [auth_code] = active_codes(email)

      # Exercise the resource-level constraint directly — independent of
      # the operations pre-check (test owns its precondition: wind to cap)
      for _attempt <- 1..5,
          do: assert({:ok, _row} = register_attempt(auth_code))

      # attempts == 5: the constraint-validated increment now fails
      assert {:error, _refused} = register_attempt(auth_code)
    end

    test "burn is single-winner — the optimistic-locked delete arbitrates (CWE-367)", %{
      email: email
    } do
      :ok = Identity.request_auth_code(email)
      _code = mailbox_code()
      [auth_code] = active_codes(email)

      assert :ok = burn(auth_code)
      # The racing loser's delete matches zero rows and errors — no mint
      assert {:error, _stale} = burn(auth_code)
    end

    test "successful verify burns the code — single-use (ADR-0003)", %{email: email} do
      :ok = Identity.request_auth_code(email)
      code = mailbox_code()

      assert {:ok, user, token} = Identity.verify_auth_code(email, code)

      rows =
        UserEmail
        |> Ash.Query.filter(user_id == ^user.id)
        |> Ash.read!(authorize?: false)

      assert [%{address: address}] = rows

      assert to_string(address) == email
      assert is_binary(token) and token != ""

      # Replay: the code no longer exists — and the burn is the arbiter
      # (optimistic lock), so a racing second consumer can never mint
      assert {:error, :no_active_code} = Identity.verify_auth_code(email, code)
    end

    test "first successful verify JIT-provisions the account — an @fluxvale.com address creates with no extra step (#478)",
         %{email: email} do
      :ok = Identity.request_auth_code(email)
      code = mailbox_code()

      assert {:ok, user, _token} = Identity.verify_auth_code(email, code)
      assert user.id
      assert user.platform_role == :user

      # A second sign-in reuses the same account — the gate never asks
      # existing users (the #478 ruling)
      :ok = Identity.request_auth_code(email)

      assert {:ok, user_again, _again_token} =
               Identity.verify_auth_code(email, mailbox_code())

      assert user_again.id == user.id
    end

    test "JIT sign-in provisions the personal org (creator = owner, #119)", %{
      email: email
    } do
      alias FluxVale.TestSupport.AccountsFixtures

      :ok = Identity.request_auth_code(email)

      assert {:ok, user, _token} = Identity.verify_auth_code(email, mailbox_code())

      org = AccountsFixtures.personal_org!(user)

      # name and slug follow the derived username (#285) — the local part
      # sanitizes into it (e.g. a negative unique integer collapses the
      # "code--123" double hyphen)
      assert org.name == user.username
      assert org.slug == user.username
    end

    test "email matching is case-insensitive", %{email: email} do
      :ok = Identity.request_auth_code(email)
      code = mailbox_code()

      upcased = String.upcase(email)

      assert {:ok, _upcased_user, _upcased_token} = Identity.verify_auth_code(upcased, code)
    end
  end

  describe "resolution (#285 T3 — table-backed identity)" do
    test "sign-in with a secondary VERIFIED address resolves the same account", %{email: email} do
      user = User.create!(email, %{}, authorize?: false)
      secondary = "verify-secondary-#{System.unique_integer()}@fluxvale.com"

      # precondition: the secondary rides the resource actions (the
      # internal verification path — the same shape the VerifyEmail op
      # drives in production)
      assert {:ok, row} = UserEmail.add(secondary, %{user: user}, authorize?: false)
      assert {:ok, _verified} = UserEmail.mark_verified(row, authorize?: false)

      assert :ok = Identity.request_auth_code(secondary)
      assert {:ok, signed_in, _token} = Identity.verify_auth_code(secondary, mailbox_code())
      assert signed_in.id == user.id
    end

    test "a pending claim on another account is superseded by the true inbox owner" do
      claimant =
        User.create!("claimant-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

      contested = "contested-#{System.unique_integer()}@fluxvale.com"

      # someone started adding the address to the claimant's account —
      # a claim with no proof
      assert {:ok, _claim} = UserEmail.add(contested, %{user: claimant}, authorize?: false)

      assert :ok = Identity.request_auth_code(contested)
      assert {:ok, fresh, _token} = Identity.verify_auth_code(contested, mailbox_code())

      # the claim was deleted; a fresh account (whose mirror owns the
      # address now) was provisioned
      refute fresh.id == claimant.id
      assert [%{user_id: owner_id, verified_at: verified, is_primary: true}] = rows_for(contested)
      assert owner_id == fresh.id
      refute is_nil(verified)
    end

    test "a claim verified before the supersede wins the address — its owner signs in, row intact" do
      claimant =
        User.create!("claimant-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

      contested = "contested-#{System.unique_integer()}@fluxvale.com"

      assert {:ok, claim} = UserEmail.add(contested, %{user: claimant}, authorize?: false)

      assert :ok = Identity.request_auth_code(contested)
      code = mailbox_code()

      # the concurrent VerifyEmail commits FIRST — the claim becomes a
      # proven address before sign-in supersedes anything
      assert {:ok, _verified} = UserEmail.mark_verified(claim, authorize?: false)

      assert {:ok, signed_in, _token} = Identity.verify_auth_code(contested, code)

      # no fork: THAT user signs in and their row is intact
      assert signed_in.id == claimant.id

      assert [%{user_id: owner_id, verified_at: verified}] = rows_for(contested)
      assert owner_id == claimant.id
      refute is_nil(verified)
    end

    test "a proof-less pending claim is superseded by a burned code — the JIT account owns the address",
         %{email: email} do
      # #287 keeps the claim posture: a pending claim confers no proof;
      # a burned code at the address supersedes it and the JIT create
      # (team domain) writes the verified signup row. No fork, no
      # wedge — the mirror-era old-pod scaffolding is gone, the claim
      # semantics stand.
      claimant =
        User.create!("vac-claimant-#{System.unique_integer()}@fluxvale.com", %{},
          authorize?: false
        )

      assert {:ok, _claim} = UserEmail.add(email, %{user: claimant}, authorize?: false)

      claims = rows_for(email)
      refute Enum.any?(claims, &(!is_nil(&1.verified_at)))

      assert :ok = Identity.request_auth_code(email)
      assert {:ok, signed_in, _token} = Identity.verify_auth_code(email, mailbox_code())

      # the claim was superseded; the address's one row is the new
      # account's verified-primary signup row
      assert signed_in.id != claimant.id
      assert [%{user_id: owner_id, verified_at: verified, is_primary: true}] = rows_for(email)
      assert owner_id == signed_in.id
      refute is_nil(verified)
    end
  end

  describe "access gate (#26 — Am. 1: the mint closes the code-TTL window)" do
    test "a rule added after the code was sent still stops the session mint",
         %{email: email} do
      # email is a @fluxvale.com address (setup) — request while unrestricted
      :ok = Identity.request_auth_code(email)
      code = mailbox_code()

      # …then the door closes to exact-address rows only
      AccessRule.create!(%{email: "one@fluxvale.com"}, authorize?: false)

      assert {:error, :not_allowed} = Identity.verify_auth_code(email, code)

      # Denied before anything burned — the code stays verifiable if the
      # rule is removed again (check-based severing, not destruction)
      assert [%{attempts: 0}] = active_codes(email)
    end
  end

  describe "invitation gate (#502 — pre-provisioned users, team-domain JIT)" do
    test "an existing external user signs in with no invitation and no behavior change" do
      # an account that predates the flow (the operator-seed shape, an
      # external domain): the gate never asks, sign-in as today
      address = "preexisting-#{System.unique_integer()}@partner.example"
      user = User.create!(address, %{}, authorize?: false)

      :ok = Identity.request_auth_code(address)

      assert {:ok, signed_in, _token} = Identity.verify_auth_code(address, mailbox_code())
      assert signed_in.id == user.id
    end

    test "a non-invited external address is refused — honest atom, no account" do
      address = "outsider-#{System.unique_integer()}@partner.example"

      :ok = Identity.request_auth_code(address)

      assert {:error, :invitation_required} = Identity.verify_auth_code(address, mailbox_code())

      assert [] = users_with_email(address)
      assert [] = rows_for(address)
    end

    test "a new team-domain address creates an account — no invitation row needed" do
      address = "team-fresh-#{System.unique_integer()}@fluxvale.com"

      :ok = Identity.request_auth_code(address)

      assert {:ok, user, _token} = Identity.verify_auth_code(address, mailbox_code())
      assert %User{} = user
    end

    test "the team bypass is an exact-suffix match — lookalikes never inherit it" do
      # the negative space the retired evaluator's tests used to pin
      # (they died with it); the boundary now lives in team_address?/1
      # and needs its lookalike arms kept here
      for lookalike <- [
            "someone-#{System.unique_integer()}@mail.fluxvale.com",
            "someone-#{System.unique_integer()}@notfluxvale.com",
            "someone-#{System.unique_integer()}@fluxvale.com.evil.example"
          ] do
        :ok = Identity.request_auth_code(lookalike)

        assert {:error, :invitation_required} =
                 Identity.verify_auth_code(lookalike, mailbox_code())
      end
    end

    test "a pending invited user refuses sign-in and the account stays inert" do
      address = "invited-#{System.unique_integer()}@partner.example"
      {invited, _raw} = invite_user!(address)

      :ok = Identity.request_auth_code(address)

      assert {:error, :invite_pending} = Identity.verify_auth_code(address, mailbox_code())

      # Inertness: acceptance is the only bootstrap, so no VERIFIED row,
      # no org — and no session minted (the error atom is the whole
      # return). #287: the reservation row stands (pending), and the
      # handle exists from birth (NOT NULL).
      assert [%{verified_at: nil}] = rows_for(address)
      assert is_binary(invited.username)

      assert {:ok, []} =
               FluxVale.Accounts.organizations_for_user(invited.id, authorize?: false)
    end

    test "a withdrawn invited user is refused like any uninvited address" do
      address = "withdrawn-#{System.unique_integer()}@partner.example"
      {invited, _raw} = invite_user!(address)
      withdraw_invite!(invited)

      :ok = Identity.request_auth_code(address)

      assert {:error, :invitation_required} = Identity.verify_auth_code(address, mailbox_code())

      # retirement keeps the reservation (#287: withdrawal kills the
      # link, never the address record) — still pending, never verified
      assert [%{verified_at: nil}] = rows_for(address)
    end

    test "an expired invited user is refused like any uninvited address" do
      address = "expired-#{System.unique_integer()}@partner.example"
      # actions cannot backdate the window — seed! is the sanctioned bypass
      expired_invited_user!(address)

      :ok = Identity.request_auth_code(address)

      assert {:error, :invitation_required} = Identity.verify_auth_code(address, mailbox_code())

      # expiry keeps the reservation too (#287's window ruling)
      assert [%{verified_at: nil}] = rows_for(address)
    end

    test "an ACCEPTED invited user signs in — the acceptance mirror row resolves them" do
      address = "accepted-#{System.unique_integer()}@partner.example"
      {_invited, raw} = invite_user!(address)
      assert {:ok, accepted, _session} = Identity.accept_invitation(raw)

      :ok = Identity.request_auth_code(address)

      assert {:ok, signed_in, _token} = Identity.verify_auth_code(address, mailbox_code())
      assert signed_in.id == accepted.id

      # the mirror row acceptance wrote is what the lookup rode
      assert [%{user_id: owner_id, verified_at: verified}] = rows_for(address)
      assert owner_id == accepted.id
      refute is_nil(verified)
    end

    test "a refused verify still burns the login code (the burn is the inbox proof)" do
      address = "burned-#{System.unique_integer()}@partner.example"

      :ok = Identity.request_auth_code(address)
      code = mailbox_code()

      assert {:error, :invitation_required} = Identity.verify_auth_code(address, code)

      # the code is gone — a retry without a fresh request cannot pass
      assert {:error, :no_active_code} = Identity.verify_auth_code(address, code)
    end
  end
end
