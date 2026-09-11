defmodule FluxVale.Identity.Operations.VerifyAuthCodeTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.AuthCodeHelpers

  alias FluxVale.Identity
  alias FluxVale.Ops.AccessRule

  setup do
    email = "verify-code-#{System.unique_integer()}@fluxvale.com"
    %{email: email}
  end

  describe "call/2" do
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

    test "email matching is case-insensitive", %{email: email} do
      :ok = Identity.request_auth_code(email)
      code = mailbox_code()

      upcased = String.upcase(email)

      assert {:ok, _upcased_user, _upcased_token} = Identity.verify_auth_code(upcased, code)
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
