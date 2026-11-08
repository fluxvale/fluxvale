defmodule FluxVale.TestSupport.UserInviteHelpers do
  @moduledoc false

  # Shared helpers for the #502 invite flow — test/support is
  # credo-exempt by config; tests own their preconditions. Invites ride
  # the real operation (actor nil + authorize?: false — the seeds
  # posture for operator-precondition rows) with a deliver that
  # discards, so nothing waits on a mailbox. Expiry and the
  # hash-without-invite shape are states actions cannot produce (no
  # backdating surface) — seed! is the sanctioned bypass there (the #23
  # janitor posture), with the hash kept derivable so tests can drive
  # the accept link. #287: seed! writes neither the username
  # (NOT NULL — passed, derived from the address like :invite does) nor
  # the reservation row (attached through :add, the InvitedEmailRow
  # shape: pending, non-primary).

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail

  @doc "Invites `address` through the real operation; returns {user, raw_token}."
  def invite_user!(address) do
    {:ok, user, raw_token} =
      Identity.invite_user(nil, address, fn _to, _url -> {:ok, :discarded} end, authorize?: false)

    {user, raw_token}
  end

  @doc "Withdraws `user`'s invite through the operation."
  def withdraw_invite!(user) do
    {:ok, _withdrawn} = Identity.withdraw_invite(nil, user, authorize?: false)
    :ok
  end

  @doc """
  Stages an EXPIRED invited user — actions cannot backdate the window,
  so seed! is the sanctioned bypass. The token hash matches
  "expired-raw" so accept-link tests can drive it. The reservation row
  rides :add (pending, non-primary) — the shape :invite writes.
  """
  def expired_invited_user!(address) do
    now = DateTime.utc_now()

    user =
      Ash.Seed.seed!(User, %{
        username: username_for(address),
        invited_at: DateTime.add(now, -14, :day),
        invite_expires_at: DateTime.truncate(DateTime.add(now, -7, :day), :second),
        invite_token_hash: User.token_hash("expired-raw")
      })

    {:ok, _reservation} = UserEmail.add(address, %{user: user}, authorize?: false)
    user
  end

  # The seed! username companion: derive from the address's local part
  # the way DeriveUsername does (the addresses these helpers receive
  # are unique_integer-keyed, so the local part is unique; reserved
  # words never appear in these prefixes).
  defp username_for(address) do
    [local | _] = String.split(to_string(address), "@", parts: 2)

    local
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]+/, "-")
    |> String.trim("-")
  end
end
