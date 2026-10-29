defmodule FluxVale.Identity.Operations.AddEmailTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.AuthCodeHelpers

  alias FluxVale.Identity
  alias FluxVale.Identity.AuthCode
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Ops.AccessRule

  require Ash.Query

  # Preconditions run authorize?: false (the house rule); the actor-ful
  # calls are the subject.
  defp user! do
    User.create!("adder-#{System.unique_integer()}@fluxvale.test", %{}, authorize?: false)
  end

  defp row_for(user_id, address) do
    UserEmail
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false)
    |> Enum.find(fn row -> to_string(row.address) == address end)
  end

  describe "call/2" do
    test "creates a pending row for the actor and sends the sign-in code" do
      user = user!()
      address = "added-#{System.unique_integer()}@fluxvale.test"

      assert {:ok, row} = Identity.add_email(user, address)
      assert row.user_id == user.id
      assert row.verified_at == nil
      assert row.is_primary == false

      # the sign-in machinery sent the code to the new inbox — no new
      # template, no new delivery path
      code = mailbox_code()
      assert String.length(code) == 6
      assert [%AuthCode{}] = active_codes(address)
    end

    test "a malformed address is refused by the resource" do
      user = user!()

      assert {:error, %Ash.Error.Invalid{}} = Identity.add_email(user, "not-an-email")
    end

    test "an AccessRule denial refuses the code send and removes the pending claim" do
      AccessRule.create!(%{domain: "fluxvale.com"}, authorize?: false)
      user = user!()
      denied = "denied-#{System.unique_integer()}@example.com"

      assert {:error, :not_allowed} = Identity.add_email(user, denied)

      # no claim left behind (round-2 P3): a refusal must not litter
      # cap slots, and a repeated denial must not pin arbitrary
      # addresses; no mail went out
      refute row_for(user.id, denied)

      refute_received {:email, _email}
    end

    test "a throttled re-send also removes the fresh claim (a claim exists only while a code is outstanding)" do
      user = user!()
      address = "throttled-#{System.unique_integer()}@fluxvale.test"

      assert {:ok, first} = Identity.add_email(user, address)
      assert :ok = Identity.remove_email(user, first.id)

      # the first send's code row is still recent, so the re-add's send
      # throttles — and the fresh claim must not survive the refusal
      assert {:error, :throttled} = Identity.add_email(user, address)

      refute row_for(user.id, address)
    end
  end
end
