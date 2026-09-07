defmodule FluxVale.Identity.Operations.RequestAuthCodeTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.TestSupport.AuthCodeHelpers

  alias FluxVale.Identity
  alias FluxVale.Identity.AuthCode

  setup do
    email = "request-code-#{System.unique_integer()}@fluxvale.com"
    %{email: email}
  end

  describe "call/2" do
    test "stores a bcrypt hash — never the code — with a 10-minute TTL", %{
      email: email
    } do
      assert :ok = Identity.request_auth_code(email)
      code = AuthCodeHelpers.mailbox_code()

      assert [%AuthCode{} = stored] = AuthCodeHelpers.active_codes(email)
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
      assert [] == AuthCodeHelpers.active_codes(email)

      # The user can immediately retry (no orphaned throttle-blocker)
      assert :ok = Identity.request_auth_code(email)
      _code = AuthCodeHelpers.mailbox_code()
    end
  end
end
