defmodule FluxVale.Identity.Operations.WithdrawInviteTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.UserInviteHelpers

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.AccountsFixtures
  require Ash.Query

  setup do
    %{address: "withdraw-#{System.unique_integer()}@partner.example"}
  end

  defp reloaded(user_id) do
    User
    |> Ash.Query.filter(id == ^user_id)
    |> Ash.Query.load(:invite_state)
    |> Ash.read_one!(authorize?: false)
  end

  describe "call/3" do
    test "stamps invite_withdrawn_at — idempotent keep-first-stamp", %{address: address} do
      {invited, _raw} = invite_user!(address)

      assert {:ok, first} = Identity.withdraw_invite(AccountsFixtures.platform_admin!(), invited)
      assert first.invite_withdrawn_at

      assert {:ok, second} = Identity.withdraw_invite(AccountsFixtures.platform_admin!(), invited)

      # a second call keeps the ORIGINAL stamp
      assert second.invite_withdrawn_at == first.invite_withdrawn_at
      assert reloaded(invited.id).invite_state == :withdrawn
    end

    test "withdraws by id too", %{address: address} do
      {invited, _raw} = invite_user!(address)

      assert {:ok, _withdrawn} =
               Identity.withdraw_invite(AccountsFixtures.platform_admin!(), invited.id,
                 authorize?: false
               )

      assert reloaded(invited.id).invite_state == :withdrawn
    end

    test "an unknown id refuses — the NotFound propagates", %{address: _address} do
      assert {:error, _not_found} =
               Identity.withdraw_invite(AccountsFixtures.platform_admin!(), Ecto.UUID.generate())
    end

    test "an accepted account is not a withdraw target — StaleRecord propagates", %{
      address: address
    } do
      {_invited, raw} = invite_user!(address)
      {:ok, accepted, _session} = Identity.accept_invitation(raw)

      assert {:error, _stale} =
               Identity.withdraw_invite(AccountsFixtures.platform_admin!(), accepted)

      # the accepted state is untouched
      assert reloaded(accepted.id).invite_state == :accepted
    end
  end
end
