defmodule FluxVale.Identity.Operations.SetPrimaryEmailTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail

  require Ash.Query

  # Preconditions run authorize?: false (the house rule); the actor-ful
  # calls are the subject.
  defp user! do
    User.create!("promoter-#{System.unique_integer()}@fluxvale.test", %{}, authorize?: false)
  end

  defp add_pending!(user, address) do
    UserEmail.add(address, %{user: user}, authorize?: false)
  end

  defp primaries(user_id) do
    UserEmail
    |> Ash.Query.filter(user_id == ^user_id and is_primary)
    |> Ash.read!(authorize?: false)
  end

  describe "call/2" do
    test "promotes a verified address and demotes the old primary" do
      user = user!()
      address = "promoted-#{System.unique_integer()}@fluxvale.test"
      {:ok, row} = add_pending!(user, address)

      # precondition: verified through the internal path
      {:ok, _verified} = UserEmail.mark_verified(row, authorize?: false)

      assert {:ok, promoted} = Identity.set_primary_email(user, row.id)
      assert promoted.is_primary

      assert [primary] = primaries(user.id)
      assert to_string(primary.address) == address
    end

    test "a pending row is refused by the resource guard" do
      user = user!()

      {:ok, pending} =
        add_pending!(user, "still-pending-#{System.unique_integer()}@fluxvale.test")

      assert {:error, %Ash.Error.Invalid{}} = Identity.set_primary_email(user, pending.id)
    end

    test "another user's row id is :not_found" do
      owner = user!()
      stranger = user!()
      {:ok, row} = add_pending!(owner, "theirs-#{System.unique_integer()}@fluxvale.test")

      assert {:error, :not_found} = Identity.set_primary_email(stranger, row.id)
    end
  end
end
