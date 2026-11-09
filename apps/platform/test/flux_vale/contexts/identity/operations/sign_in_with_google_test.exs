defmodule FluxVale.Identity.Operations.SignInWithGoogleTest do
  @moduledoc false

  # The operation-resolvable rows of plan §4's edge table: PLAIN
  # claims maps (the assent layer has its own suite in
  # google_oidc_test.exs). Admission parity is the whole design: every
  # ladder arm mirrors VerifyAuthCodeTest's posture.

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.UserInviteHelpers

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Ops.AccessRule
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.Telemetry
  require Ash.Query

  setup do
    email = "google-#{System.unique_integer()}@fluxvale.com"
    %{email: email}
  end

  # The assent user map for a verified address — string keys, exactly
  # what GoogleOIDC.callback/3 hands the web layer.
  defp claims_for(address, email_verified \\ true) do
    %{"email" => address, "email_verified" => email_verified, "sub" => "google-sub-1"}
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

  describe "call/1 — the strict gate (plan §4 guardrail 1)" do
    test "anything but a literal true email_verified refuses BEFORE any lookup" do
      address = "unverified-#{System.unique_integer()}@fluxvale.com"

      for claims <- [
            claims_for(address, false),
            claims_for(address, nil),
            claims_for(address, "true"),
            %{"email_verified" => true},
            %{"email" => "", "email_verified" => true}
          ] do
        assert {:error, :email_not_verified} = Identity.sign_in_with_google(claims)
      end

      # No side effects: no account, no rows — the gate is ahead of
      # the AccessRules check and the lookup entirely
      assert [] = users_with_email(address)
      assert [] = rows_for(address)
    end

    test "an unverified claim reports its outcome, nothing else", %{email: email} do
      Telemetry.capture_events([Identity.google_sign_in_event()])

      claims = claims_for(email, false)

      assert {:error, :email_not_verified} = Identity.sign_in_with_google(claims)

      assert_receive {:telemetry_event, [:flux_vale, :identity, :google_sign_in], %{count: 1},
                      %{outcome: :email_not_verified}}
    end

    test "a malformed email is an unverified claim — never :provisioning_failed" do
      # team-suffix malformed claims would pass a binary+non-empty-only
      # gate, survive the lookups, and die at the JIT create's
      # validation — leaking a shape difference. valid_address? (the
      # code-send gate's own rule) refuses it at the gate.
      claims = %{"email" => "a@b@fluxvale.com", "email_verified" => true}

      assert {:error, :email_not_verified} = Identity.sign_in_with_google(claims)

      assert [] = users_with_email("a@b@fluxvale.com")
      assert [] = rows_for("a@b@fluxvale.com")
    end

    test "an unverified claim against an EXISTING account refuses — the takeover guard, pinned" do
      # §4's attacker shape: an IdP account bearing the victim's
      # address WITHOUT Google's verification. The strict gate is the
      # only thing between that claim and the victim's session.
      address = "guard-#{System.unique_integer()}@fluxvale.com"
      victim = User.create!(address, %{}, authorize?: false)

      claims = claims_for(address, false)

      assert {:error, :email_not_verified} = Identity.sign_in_with_google(claims)

      # no session, no fork, the account untouched
      assert [%User{} = untouched] = users_with_email(address)
      assert untouched.id == victim.id
      assert [%{user_id: owner_id, verified_at: verified}] = rows_for(address)
      assert owner_id == victim.id
      refute is_nil(verified)
    end

    test "the strict gate runs BEFORE the AccessRules check — order pinned" do
      # denied address + unverified claim: :email_not_verified (not
      # :not_allowed) proves the gate is first, as its comment claims
      AccessRule.create!(%{email: "one@fluxvale.com"}, authorize?: false)

      address = "denied-#{System.unique_integer()}@example.com"
      claims = claims_for(address, false)

      assert {:error, :email_not_verified} = Identity.sign_in_with_google(claims)
    end
  end

  describe "call/1 — resolution (the admission ladder, rung for rung)" do
    test "a verified-email match signs in to the existing account — the auto-link (plan §4)",
         %{email: email} do
      Telemetry.capture_events([Identity.google_sign_in_event()])

      user = User.create!(email, %{}, authorize?: false)

      claims = claims_for(email)
      assert {:ok, signed_in, token} = Identity.sign_in_with_google(claims)
      assert signed_in.id == user.id
      assert is_binary(token) and token != ""

      assert_receive {:telemetry_event, [:flux_vale, :identity, :google_sign_in], %{count: 1},
                      %{outcome: :ok}}
    end

    test "an AccessRule-denied address refuses at entry — no account touched" do
      # any rows = allowlist (ADR-0023): one rule for someone else
      # denies every other address
      AccessRule.create!(%{email: "one@fluxvale.com"}, authorize?: false)

      address = "denied-#{System.unique_integer()}@example.com"

      claims = claims_for(address)
      assert {:error, :not_allowed} = Identity.sign_in_with_google(claims)

      assert [] = users_with_email(address)
      assert [] = rows_for(address)
    end

    test "a pending claim on the address is superseded — the JIT account owns it, never a fork",
         %{email: email} do
      claimant =
        User.create!("claimant-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

      # someone started adding the address to the claimant's account —
      # a claim with no proof; the Google proof supersedes it
      assert {:ok, _claim} = UserEmail.add(email, %{user: claimant}, authorize?: false)

      claims = claims_for(email)
      assert {:ok, fresh, _token} = Identity.sign_in_with_google(claims)

      refute fresh.id == claimant.id
      assert [%{user_id: owner_id, verified_at: verified, is_primary: true}] = rows_for(email)
      assert owner_id == fresh.id
      refute is_nil(verified)
    end

    test "auto-link on a verified claim created outside the flow — top-of-flow lookup, no fork" do
      # The flip happened BEFORE the call, so the rung this exercises
      # is the top-of-flow get_by_email (rung 1), not the
      # post-supersede re-lookup — that rung needs the flip to commit
      # between the supersede and the re-read, which no sequential
      # test can arrange (see the exclusion in the operation).
      claimant =
        User.create!("flip-claimant-#{System.unique_integer()}@fluxvale.com", %{},
          authorize?: false
        )

      contested = "flip-#{System.unique_integer()}@fluxvale.com"

      {:ok, claim} = UserEmail.add(contested, %{user: claimant}, authorize?: false)
      assert {:ok, _verified} = UserEmail.mark_verified(claim, authorize?: false)

      claims = claims_for(contested)
      assert {:ok, signed_in, _token} = Identity.sign_in_with_google(claims)
      assert signed_in.id == claimant.id

      assert [%{user_id: owner_id, verified_at: verified}] = rows_for(contested)
      assert owner_id == claimant.id
      refute is_nil(verified)
    end
  end

  describe "call/1 — the invitation gate (#502 parity)" do
    test "an outstanding invite refuses :invite_pending and NEVER forks the account" do
      address = "invited-#{System.unique_integer()}@partner.example"
      {invited, _raw} = invite_user!(address)

      claims = claims_for(address)
      assert {:error, :invite_pending} = Identity.sign_in_with_google(claims)

      # one account, reservation intact and pending — the emailed link
      # is the credential
      assert [%User{} = invited_again] = users_with_email(address)
      assert invited_again.id == invited.id
      assert [%{verified_at: nil}] = rows_for(address)
    end

    test "a withdrawn invite is refused like any uninvited address" do
      address = "withdrawn-#{System.unique_integer()}@partner.example"
      {invited, _raw} = invite_user!(address)
      withdraw_invite!(invited)

      claims = claims_for(address)
      assert {:error, :invitation_required} = Identity.sign_in_with_google(claims)
      assert [%{verified_at: nil}] = rows_for(address)
    end

    test "an expired invite is refused like any uninvited address" do
      address = "expired-#{System.unique_integer()}@partner.example"
      expired_invited_user!(address)

      claims = claims_for(address)
      assert {:error, :invitation_required} = Identity.sign_in_with_google(claims)
      assert [%{verified_at: nil}] = rows_for(address)
    end

    test "an unknown non-team address hits the wall — no account created" do
      address = "outsider-#{System.unique_integer()}@partner.example"

      claims = claims_for(address)
      assert {:error, :invitation_required} = Identity.sign_in_with_google(claims)

      assert [] = users_with_email(address)
      assert [] = rows_for(address)
    end

    test "the team bypass is an exact-suffix match — lookalikes never inherit it" do
      for lookalike <- [
            "someone-#{System.unique_integer()}@mail.fluxvale.com",
            "someone-#{System.unique_integer()}@notfluxvale.com",
            "someone-#{System.unique_integer()}@fluxvale.com.evil.example"
          ] do
        claims = claims_for(lookalike)

        assert {:error, :invitation_required} =
                 Identity.sign_in_with_google(claims)
      end
    end
  end

  describe "call/1 — the team-domain JIT (plan §4: unknown @fluxvale.com creates)" do
    test "an unknown team address creates, fires both counters, and provisions the account",
         %{email: email} do
      Telemetry.capture_events([Identity.signup_event(), Identity.google_sign_in_event()])

      claims = claims_for(email)
      assert {:ok, user, token} = Identity.sign_in_with_google(claims)
      assert %User{} = user
      assert is_binary(token) and token != ""

      # same semantic event as the email arm's JIT (plan §10), plus
      # the arm's own outcome counter
      assert_receive {:telemetry_event, [:flux_vale, :identity, :signup], %{count: 1}, %{}}

      assert_receive {:telemetry_event, [:flux_vale, :identity, :google_sign_in], %{count: 1},
                      %{outcome: :ok}}

      # account shape identical to an email-code signup: verified
      # primary row, personal org provisioned
      assert [%{address: address, verified_at: verified, is_primary: true}] = rows_for(email)
      assert to_string(address) == email
      refute is_nil(verified)

      org = AccountsFixtures.personal_org!(user)
      assert org.name == user.username
      assert org.slug == user.username
    end
  end
end
