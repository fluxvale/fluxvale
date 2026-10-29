defmodule FluxVale.Identity.Operations.VerifyEmailTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.AuthCodeHelpers

  alias FluxVale.Identity
  alias FluxVale.Identity.AuthCode
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail

  # Preconditions run authorize?: false (the house rule); the actor-ful
  # calls are the subject.
  defp user! do
    User.create!("verifier-#{System.unique_integer()}@fluxvale.test", %{}, authorize?: false)
  end

  defp fresh_row!(row_id) do
    Ash.get!(UserEmail, row_id, authorize?: false)
  end

  describe "call/3" do
    test "verifies the pending row with the real code from the inbox" do
      user = user!()
      address = "verify-me-#{System.unique_integer()}@fluxvale.test"
      {:ok, row} = Identity.add_email(user, address)
      code = mailbox_code()

      assert {:ok, verified} = Identity.verify_email(user, row.id, code)
      refute is_nil(verified.verified_at)

      # replay: the row is no longer pending, and the code is burned
      assert {:error, :not_pending} = Identity.verify_email(user, row.id, code)
      assert active_codes(address) == []
    end

    test "a wrong code counts the attempt and leaves the row pending" do
      user = user!()
      address = "wrong-code-#{System.unique_integer()}@fluxvale.test"
      {:ok, row} = Identity.add_email(user, address)
      _code = mailbox_code()

      assert {:error, :wrong_code} = Identity.verify_email(user, row.id, "000000")

      assert %{verified_at: nil} = fresh_row!(row.id)
      assert [%{attempts: 1}] = active_codes(address)
    end

    test "an expired code is :no_active_code and the row stays pending" do
      user = user!()
      address = "expired-#{System.unique_integer()}@fluxvale.test"

      # precondition: a pending row and an already-expired code (a state
      # the actions cannot produce — the create always stamps a live TTL)
      {:ok, row} = UserEmail.add(address, %{user: user}, authorize?: false)

      {:ok, _expired} =
        AuthCode
        |> Ash.Changeset.for_create(:create, %{
          email: address,
          code_hash: Bcrypt.hash_pwd_salt("123456"),
          expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
        })
        |> Ash.create(authorize?: false)

      assert {:error, :no_active_code} = Identity.verify_email(user, row.id, "123456")
      assert %{verified_at: nil} = fresh_row!(row.id)
    end

    test "locks out after five wrong attempts (the cap is the backoff, as in sign-in)" do
      user = user!()
      address = "lockout-#{System.unique_integer()}@fluxvale.test"
      {:ok, row} = Identity.add_email(user, address)
      _code = mailbox_code()

      for _attempt <- 1..5,
          do: assert({:error, :wrong_code} = Identity.verify_email(user, row.id, "000000"))

      assert {:error, :locked_out} = Identity.verify_email(user, row.id, "000000")
      assert %{verified_at: nil} = fresh_row!(row.id)
    end

    test "an unknown row id is :not_found" do
      user = user!()

      assert {:error, :not_found} = Identity.verify_email(user, Ash.UUID.generate(), "000000")
    end

    test "another user's row id is :not_found — :mine is the owner scope" do
      owner = user!()
      stranger = user!()

      {:ok, row} =
        UserEmail.add("theirs-#{System.unique_integer()}@fluxvale.test", %{user: owner},
          authorize?: false
        )

      assert {:error, :not_found} = Identity.verify_email(stranger, row.id, "000000")
    end

    test "an already-verified row is :not_pending" do
      user = user!()

      # precondition: verified through the internal path (the designed
      # mark_verified posture)
      {:ok, row} =
        UserEmail.add("already-#{System.unique_integer()}@fluxvale.test", %{user: user},
          authorize?: false
        )

      {:ok, _verified} = UserEmail.mark_verified(row, authorize?: false)

      assert {:error, :not_pending} = Identity.verify_email(user, row.id, "000000")
    end
  end
end
