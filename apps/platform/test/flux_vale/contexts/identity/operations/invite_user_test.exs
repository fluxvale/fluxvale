defmodule FluxVale.Identity.Operations.InviteUserTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.UserInviteHelpers

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.TestSupport.AccountsFixtures
  require Ash.Query

  setup do
    %{address: "invitee-#{System.unique_integer()}@partner.example"}
  end

  defp admin_actor do
    AccountsFixtures.platform_admin!()
  end

  defp users_with_email(address) do
    User
    |> Ash.Query.filter(email == ^address)
    |> Ash.read!(authorize?: false)
  end

  defp emails_of(user_id) do
    UserEmail
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false)
  end

  describe "call/4 — the create arm" do
    test "creates a pre-provisioned inert account and returns the raw token exactly once", %{
      address: address
    } do
      {:ok, user, raw} =
        Identity.invite_user(admin_actor(), address, fn _to, _url -> {:ok, :sent} end)

      assert %User{} = user
      assert user.invited_at
      assert user.invite_expires_at
      refute user.invite_accepted_at
      refute user.invite_withdrawn_at
      refute user.username

      # the row stores the SHA-256 alone — the raw value never lands
      assert user.invite_token_hash == User.token_hash(raw)
      refute user.invite_token_hash == raw

      # inertness: no verified email row, no org (no wallet either —
      # the wallet rides the org)
      assert [] = emails_of(user.id)

      assert {:ok, []} =
               FluxVale.Accounts.organizations_for_user(user.id, authorize?: false)

      reloaded =
        address
        |> users_with_email()
        |> List.first()
        |> Ash.load!(:invite_state, authorize?: false)

      assert reloaded.invite_state == :pending
    end

    test "an unsendable address is refused before anything is written" do
      assert {:error, :invalid_address} = Identity.invite_user(admin_actor(), "not-an-address")
    end

    test "delivery failure of any shape does not fail the invite — the row is durable", %{
      address: address
    } do
      assert {:ok, user, _raw} =
               Identity.invite_user(admin_actor(), address, fn _to, _url -> {:error, :boom} end)

      assert [%User{}] = users_with_email(address)
      assert user.invited_at
    end

    test "a raising deliver is tolerated", %{address: address} do
      deliver = fn _to, _url -> raise "smtp on fire" end

      assert {:ok, _user, _raw} = Identity.invite_user(admin_actor(), address, deliver)
      assert [%User{}] = users_with_email(address)
    end

    test "a throwing deliver is tolerated", %{address: address} do
      deliver = fn _to, _url -> throw(:adapter_exited) end

      assert {:ok, _user, _raw} = Identity.invite_user(admin_actor(), address, deliver)
      assert [%User{}] = users_with_email(address)
    end

    test "a non-admin actor is default-forbidden", %{address: address} do
      civilian = AccountsFixtures.user!()

      assert {:error, _forbidden} =
               Identity.invite_user(civilian, address, fn _to, _url -> {:ok, :sent} end)

      assert [] = users_with_email(address)
    end
  end

  describe "call/4 — the reinvite arm (the resend lever)" do
    test "refreshes the stamps, clears withdrawal, and mints a new token", %{address: address} do
      {:ok, user, raw1} =
        Identity.invite_user(nil, address, fn _to, _url -> {:ok, :sent} end, authorize?: false)

      withdraw_invite!(user)

      {:ok, reinvited, raw2} =
        Identity.invite_user(admin_actor(), address, fn _to, _url -> {:ok, :sent} end)

      assert reinvited.id == user.id
      assert raw2 != raw1
      assert reinvited.invite_token_hash == User.token_hash(raw2)
      refute reinvited.invite_withdrawn_at
      assert DateTime.after?(reinvited.invited_at, user.invited_at)

      # :utc_datetime truncates to seconds — the fresh window is
      # now-or-later, never earlier
      assert DateTime.compare(reinvited.invite_expires_at, user.invite_expires_at) != :lt
    end

    test "re-inviting a withdrawn account clears the withdrawal at the state level", %{
      address: address
    } do
      {user, _raw1} = invite_user!(address)
      withdraw_invite!(user)

      {:ok, reinvited, _raw2} =
        Identity.invite_user(admin_actor(), address, fn _to, _url -> {:ok, :sent} end)

      reloaded = Ash.load!(reinvited, :invite_state, authorize?: false)

      assert reloaded.invite_state == :pending
    end
  end

  describe "call/4 — the :already_active fork (both occupant surfaces)" do
    test "a verified-row occupant (a normal account) is already active", %{address: address} do
      User.create!(address, %{}, authorize?: false)

      assert {:error, :already_active} =
               Identity.invite_user(admin_actor(), address, fn _to, _url -> {:ok, :sent} end)
    end

    test "an accepted invited user (verified mirror row) is already active", %{address: address} do
      {_invited, raw} = invite_user!(address)
      assert {:ok, _accepted, _session} = Identity.accept_invitation(raw)

      assert {:error, :already_active} =
               Identity.invite_user(admin_actor(), address, fn _to, _url -> {:ok, :sent} end)
    end

    test "a frozen-mirror-only occupant (the old-pod shape) is already active", %{
      address: address
    } do
      # actions cannot produce the shape (the create mirror stamps a
      # row) — seed! is the sanctioned bypass (the review P2-3 shape)
      Ash.Seed.seed!(User, %{email: address})

      assert {:error, :already_active} =
               Identity.invite_user(admin_actor(), address, fn _to, _url -> {:ok, :sent} end)
    end
  end
end
