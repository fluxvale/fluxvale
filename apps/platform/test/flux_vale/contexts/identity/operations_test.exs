defmodule FluxVale.Identity.OperationsTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import Swoosh.TestAssertions

  alias FluxVale.Identity
  alias FluxVale.Identity.AuthCode
  alias FluxVale.Repo

  # Swoosh test adapter captures into the process mailbox (per-test)
  setup do
    email = "ops-test-#{System.unique_integer()}@fluxvale.com"
    %{email: email}
  end

  defp mailbox_code do
    assert_receive {:email, %Swoosh.Email{text_body: body}},
                   1_000,
                   "expected the auth-code email to be delivered"

    [code] = Regex.run(~r/code is (\d{6})\./, body, capture: :all_but_first)
    code
  end

  describe "request_auth_code/1" do
    test "stores a bcrypt hash — never the code — with a 10-minute TTL", %{
      email: email
    } do
      assert :ok = Identity.request_auth_code(email)
      code = mailbox_code()

      assert [%AuthCode{} = stored] = active_codes(email)
      assert stored.code_hash != code
      assert String.starts_with?(stored.code_hash, "$2")
      assert Bcrypt.verify_pass(code, stored.code_hash)

      assert_in_delta DateTime.to_unix(stored.expires_at),
                      DateTime.to_unix(DateTime.utc_now()) + 10 * 60,
                      5
    end

    test "throttles resends per address (ADR-0003 send throttle)", %{email: email} do
      assert :ok = Identity.request_auth_code(email)
      assert {:error, :throttled} = Identity.request_auth_code(email)
      assert {:error, :throttled} = Identity.request_auth_code(email)
    end

    test "failed delivery burns the code — retries aren't blocked (review)", %{
      email: email
    } do
      boom = fn _to, _code -> {:error, :boom} end

      assert {:error, :delivery_failed} = Identity.request_auth_code(email, boom)
      assert [] == active_codes(email)

      # The user can immediately retry (no orphaned throttle-blocker)
      assert :ok = Identity.request_auth_code(email)
      _code = mailbox_code()
    end
  end

  describe "verify_auth_code/2" do
    test "wrong code increments attempts and stays verifiable", %{email: email} do
      :ok = Identity.request_auth_code(email)
      code = mailbox_code()

      assert {:error, :wrong_code} = Identity.verify_auth_code(email, "00000")

      assert [%AuthCode{attempts: 1}] = active_codes(email)
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

      assert {:ok, user, token} = Identity.verify_auth_code(email, code)
      assert user.id
      assert user.platform_role == :user

      # A second sign-in reuses the same account
      :ok = Identity.request_auth_code(email)
      assert {:ok, user_again, _again_token} = Identity.verify_auth_code(email, mailbox_code())
      assert user_again.id == user.id
    end

    test "email matching is case-insensitive", %{email: email} do
      :ok = Identity.request_auth_code(email)
      code = mailbox_code()

      upcased = String.upcase(email)
      assert {:ok, _upcased_user, _upcased_token} = Identity.verify_auth_code(upcased, code)
    end
  end

  defp active_codes(email) do
    import Ash.Query

    AuthCode
    |> Ash.Query.for_read(:active_for_email, %{email: email})
    |> Ash.Query.set_context(%{private: %{ash_authentication?: true}})
    |> Ash.read!()
  end
end
