defmodule FluxVale.Identity.Operations.ResolveInviteLinkTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  import FluxVale.TestSupport.UserInviteHelpers

  alias FluxVale.Identity
  alias FluxVale.Identity.User

  describe "call/1 — the states" do
    test "a fresh invite reads :pending" do
      {_user, raw} = invite_user!("resolve-#{System.unique_integer()}@partner.example")

      assert {:ok, :pending} = Identity.resolve_invite_link(raw)
    end

    test "an accepted invite reads :accepted" do
      {_user, raw} = invite_user!("resolve-#{System.unique_integer()}@partner.example")
      {:ok, _user, _token} = Identity.accept_invitation(raw)

      assert {:ok, :accepted} = Identity.resolve_invite_link(raw)
    end

    test "a withdrawn invite reads :withdrawn" do
      {user, raw} = invite_user!("resolve-#{System.unique_integer()}@partner.example")
      withdraw_invite!(user)

      assert {:ok, :withdrawn} = Identity.resolve_invite_link(raw)
    end

    test "an expired invite reads :expired" do
      # actions cannot backdate the window — seed! is the sanctioned bypass
      expired_invited_user!("resolve-expired-#{System.unique_integer()}@partner.example")

      assert {:ok, :expired} = Identity.resolve_invite_link("expired-raw")
    end
  end

  describe "call/1 — the unknown arms" do
    test "an unknown token refuses" do
      assert {:error, :unknown_token} = Identity.resolve_invite_link("no-such-token")
    end

    test "a missing param (nil) is an unknown token, not a crash" do
      assert {:error, :unknown_token} = Identity.resolve_invite_link(nil)
    end

    test "a hash with no invite stamps is an unknown token" do
      # structurally unreachable through actions (the hash is only ever
      # written alongside invited_at) — seed! is the sanctioned bypass
      # for the hand-built shape
      address = "orphan-#{System.unique_integer()}@partner.example"
      Ash.Seed.seed!(User, %{email: address, invite_token_hash: User.token_hash("orphan")})

      assert {:error, :unknown_token} = Identity.resolve_invite_link("orphan")
    end
  end
end
