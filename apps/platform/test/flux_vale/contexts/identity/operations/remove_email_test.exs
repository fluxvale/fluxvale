defmodule FluxVale.Identity.Operations.RemoveEmailTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.AuthCodeHelpers

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail

  require Ash.Query

  # Preconditions run authorize?: false (the house rule); the actor-ful
  # calls are the subject.
  defp user! do
    User.create!("remover-#{System.unique_integer()}@fluxvale.test", %{}, authorize?: false)
  end

  defp add_pending!(user, address) do
    UserEmail.add(address, %{user: user}, authorize?: false)
  end

  defp mirror_row!(user) do
    UserEmail
    |> Ash.Query.filter(user_id == ^user.id and is_primary)
    |> Ash.read_one!(authorize?: false)
  end

  describe "call/2" do
    test "removes a pending claim" do
      user = user!()
      {:ok, pending} = add_pending!(user, "churn-#{System.unique_integer()}@fluxvale.test")

      assert :ok = Identity.remove_email(user, pending.id)
      assert match?({:error, _not_found}, Ash.get(UserEmail, pending.id, authorize?: false))
    end

    test "the primary is refused by the resource guard" do
      user = user!()
      primary = mirror_row!(user)

      assert {:error, %Ash.Error.Invalid{}} = Identity.remove_email(user, primary.id)
    end

    test "the demoted signup address is refused — it is frozen into users.email (#285 T3 §5)" do
      user = user!()
      switched = "switched-#{System.unique_integer()}@fluxvale.test"

      {:ok, row} = Identity.add_email(user, switched)
      code = mailbox_code()
      {:ok, _verified} = Identity.verify_email(user, row.id, code)
      {:ok, _promoted} = Identity.set_primary_email(user, row.id)

      old =
        UserEmail
        |> Ash.Query.filter(address == ^user.email)
        |> Ash.read_one!(authorize?: false)

      assert {:error, %Ash.Error.Invalid{errors: [%{message: message}]}} =
               Identity.remove_email(user, old.id)

      assert message =~ "frozen"
    end

    test "another user's row id is :not_found" do
      owner = user!()
      stranger = user!()
      {:ok, row} = add_pending!(owner, "theirs-#{System.unique_integer()}@fluxvale.test")

      assert {:error, :not_found} = Identity.remove_email(stranger, row.id)
    end

    # The whole management cycle across the four ops (#285 T3), with a
    # real inbox code at the verify step.
    test "the cycle: add → verify (real code) → set_primary → remove" do
      user = user!()
      new_address = "cycle-#{System.unique_integer()}@fluxvale.test"

      # the mirror (signup address) is the primary to be replaced
      old = mirror_row!(user)

      {:ok, row} = Identity.add_email(user, new_address)
      code = mailbox_code()
      {:ok, _verified} = Identity.verify_email(user, row.id, code)

      {:ok, _promoted} = Identity.set_primary_email(user, row.id)

      # the demoted signup address is frozen into users.email — it stays
      # (see RemoveGuard); a verified non-primary address removes cleanly
      assert {:error, %Ash.Error.Invalid{}} = Identity.remove_email(user, old.id)

      spare = "cycle-spare-#{System.unique_integer()}@fluxvale.test"
      {:ok, spare_row} = Identity.add_email(user, spare)
      spare_code = mailbox_code()
      {:ok, _spare_verified} = Identity.verify_email(user, spare_row.id, spare_code)
      assert :ok = Identity.remove_email(user, spare_row.id)

      remaining =
        UserEmail
        |> Ash.Query.filter(user_id == ^user.id)
        |> Ash.read!(authorize?: false)

      # exactly the frozen mirror and the new primary survive
      assert length(remaining) == 2

      assert new_address in Enum.map(remaining, &to_string(&1.address))
    end
  end
end
