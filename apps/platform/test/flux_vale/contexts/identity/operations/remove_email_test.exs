defmodule FluxVale.Identity.Operations.RemoveEmailTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.AuthCodeHelpers

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.TestSupport.AccountsFixtures

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

    test "the demoted signup address is REMOVABLE — the frozen-mirror guard died with the column (#287)" do
      user = user!()
      signup = AccountsFixtures.primary_address!(user)
      switched = "switched-#{System.unique_integer()}@fluxvale.test"

      {:ok, row} = Identity.add_email(user, switched)
      code = mailbox_code()
      {:ok, _verified} = Identity.verify_email(user, row.id, code)
      {:ok, _promoted} = Identity.set_primary_email(user, row.id)

      old =
        UserEmail
        |> Ash.Query.filter(address == ^signup)
        |> Ash.read_one!(authorize?: false)

      # post-#287 the signup row is an ordinary address: demoted and
      # not the last verified, it goes — the mirror-era permanent
      # freeze went with the column
      assert :ok = Identity.remove_email(user, old.id)
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

      # post-#287 the demoted signup address is ordinary: verified,
      # non-primary, siblings remaining — it removes cleanly
      assert :ok = Identity.remove_email(user, old.id)

      spare = "cycle-spare-#{System.unique_integer()}@fluxvale.test"
      {:ok, spare_row} = Identity.add_email(user, spare)
      spare_code = mailbox_code()
      {:ok, _spare_verified} = Identity.verify_email(user, spare_row.id, spare_code)
      assert :ok = Identity.remove_email(user, spare_row.id)

      remaining =
        UserEmail
        |> Ash.Query.filter(user_id == ^user.id)
        |> Ash.read!(authorize?: false)

      # exactly the new primary survives
      assert length(remaining) == 1

      assert new_address in Enum.map(remaining, &to_string(&1.address))
    end
  end
end
