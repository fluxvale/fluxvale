defmodule FluxVale.Accounts.MembershipInvite.AcceptMembership do
  @moduledoc """
  The join half of the accept transaction (slice 4 of #408): creates
  the invitee's Membership row inside the same transaction that stamps
  `accepted_at` — before_action hooks run inside the data layer's
  transaction, so a membership failure rolls the whole accept back
  (no accepted_at without a membership, never a half-join).

  Role comes from the invite (the single enum axis; this flow writes
  `:member` only), user identity comes from the action's private
  `user_id` argument that AcceptInvite's email fence resolved.
  authorize?: false is the token-path posture: the operation's token
  lookup and verified-primary match ARE the authorization, and the
  Membership create policy stays system-only for every actor path.
  A duplicate join (raced past the operation's pre-check) fails on
  Membership's unique_user_per_org identity and rolls back with it —
  the index is the race arbiter (the unique_slug posture).
  """

  use Ash.Resource.Change

  alias FluxVale.Accounts.Membership

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &join_org/1)
  end

  defp join_org(changeset) do
    invite = changeset.data
    user_id = Ash.Changeset.get_argument(changeset, :user_id)

    # The error is ADDED, not raised: the accept action returns
    # {:error, _} and the transaction unwinds whole (the caller never
    # sees a half-join as a crash).
    case Membership.create(
           %{organization_id: invite.organization_id, user_id: user_id, role: invite.role},
           authorize?: false
         ) do
      {:ok, _membership} ->
        changeset

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  # The before_action hook cannot run atomically (the set_primary
  # trade — declared on the :accept action).
  @impl Ash.Resource.Change
  def atomic?, do: false
end
