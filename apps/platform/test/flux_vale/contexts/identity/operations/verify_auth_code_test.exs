defmodule FluxVale.Identity.Operations.VerifyAuthCodeTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.AuthCodeHelpers

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

  defp users_with_email(email) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read!(authorize?: false)
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
      assert to_string(user.email) == email
      assert is_binary(token) and token != ""

      # Replay: the code no longer exists — and the burn is the arbiter
      # (optimistic lock), so a racing second consumer can never mint
      assert {:error, :no_active_code} = Identity.verify_auth_code(email, code)
    end

    test "first successful verify JIT-provisions the account", %{email: email} do
      :ok = Identity.request_auth_code(email)
      code = mailbox_code()

      assert {:ok, user, _token} = Identity.verify_auth_code(email, code)
      assert user.id
      assert user.platform_role == :user

      # A second sign-in reuses the same account
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

    test "a pre-T3 user (users.email only, no rows) signs in healed — same account, one verified row",
         %{email: email} do
      # A state actions cannot produce (the create mirror stamps a row) —
      # seed! is the sanctioned bypass; this is the old-pod shape
      # (review P2-3)
      old_pod = Ash.Seed.seed!(User, %{email: email})

      assert :ok = Identity.request_auth_code(email)
      assert {:ok, signed_in, _token} = Identity.verify_auth_code(email, mailbox_code())

      assert signed_in.id == old_pod.id

      # the heal wrote the mirror row the create path would have —
      # verified and primary — and no second account exists
      assert [%{user_id: owner_id, verified_at: verified, is_primary: true}] = rows_for(email)
      assert owner_id == old_pod.id
      refute is_nil(verified)
      assert [%User{}] = users_with_email(email)
    end

    test "a pending self-claim on an old-pod account is superseded — the heal lands, nothing wedges",
         %{email: email} do
      # old-pod shape: users.email holds the address, no user_emails row
      old_pod = Ash.Seed.seed!(User, %{email: email})

      # the account re-claims its own address (the owner-only add policy
      # allows exactly this) — a pending row whose address matches the
      # frozen users.email
      assert {:ok, _claim} = UserEmail.add(email, %{user: old_pod}, authorize?: false)

      assert :ok = Identity.request_auth_code(email)
      assert {:ok, signed_in, _token} = Identity.verify_auth_code(email, mailbox_code())

      # the atomic supersede removed the claim (RemoveGuard's frozen-
      # mirror leg would have refused it and wedged the account) and the
      # collision heal wrote the mirror row
      assert signed_in.id == old_pod.id
      assert [%{user_id: owner_id, verified_at: verified, is_primary: true}] = rows_for(email)
      assert owner_id == old_pod.id
      refute is_nil(verified)
    end

    test "an old-pod account already at the address cap signs in refused — atom-shaped, nothing healed",
         %{email: email} do
      # The heal's else arm: a pre-T3 user who spent their cap on other
      # addresses cannot gain a 6th row for the signup address — the
      # honest answer is the atom-shaped refusal, not a wedging raise
      # and not a lie. (A real operator path exists: free a slot.)
      old_pod = Ash.Seed.seed!(User, %{email: email})

      for n <- 1..UserEmail.max_emails_per_user() do
        address = "verify-capped-#{n}-#{System.unique_integer()}@fluxvale.com"
        assert {:ok, _row} = UserEmail.add(address, %{user: old_pod}, authorize?: false)
      end

      assert :ok = Identity.request_auth_code(email)

      # the atom shape is the contract: the bare-with arm used to leak
      # %Ash.Error.Invalid{} out of call/2
      assert {:error, :address_unresolved} = Identity.verify_auth_code(email, mailbox_code())

      # nothing healed: still exactly the five rows, no signup row
      assert [] = rows_for(email)
      assert [%User{}] = users_with_email(email)
    end

    test "an old-pod account that already promoted a second primary still signs in — the heal attaches the signup row non-primary",
         %{email: email} do
      # The p17 wedge (round-2 P1): a pre-T3 account served by a new pod
      # during a rolling deploy adds and promotes a second address, then
      # signs in with the SIGNUP address. The heal used to force
      # is_primary: true — colliding the at-most-one-primary index,
      # escaping call/2's {:error, atom()} contract as a non-atom
      # %Ash.Error.Invalid{}, and burning a code per attempt forever.
      old_pod = Ash.Seed.seed!(User, %{email: email})
      second = "verify-wedge-#{System.unique_integer()}@fluxvale.com"

      assert {:ok, row} = UserEmail.add(second, %{user: old_pod}, authorize?: false)
      assert {:ok, _verified} = UserEmail.mark_verified(row, authorize?: false)
      assert {:ok, _promoted} = UserEmail.set_primary(row, actor: old_pod, authorize?: true)

      assert :ok = Identity.request_auth_code(email)

      # the {:ok, _, _} SHAPE is the assertion: an error class escaping
      # here fails the pattern match (and would not be an atom)
      assert {:ok, signed_in, _token} = Identity.verify_auth_code(email, mailbox_code())
      assert signed_in.id == old_pod.id

      # the healed signup row is verified but NON-primary — the promoted
      # second address keeps primary; no second account exists
      assert [%{user_id: owner_id, verified_at: verified, is_primary: false}] = rows_for(email)
      assert owner_id == old_pod.id
      refute is_nil(verified)

      assert [%{user_id: second_owner_id, is_primary: true}] = rows_for(second)
      assert second_owner_id == old_pod.id

      assert [%User{}] = users_with_email(email)
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
end
