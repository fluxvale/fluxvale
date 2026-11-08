defmodule FluxVale.Identity.UserEmail.RemoveGuard do
  @moduledoc """
  Guards address removal: the primary cannot go (switch first), a
  user's last verified address cannot go either — every account keeps
  at least one proven address — and an unaccepted invitation's
  reservation cannot go (no surface may orphan an invite, #287).
  All checks run before_action inside the destroy transaction.
  """

  use Ash.Resource.Change

  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail

  require Ash.Query

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Ash.get(UserEmail, changeset.data.id, authorize?: false) do
        {:error, _not_found} ->
          # The row vanished between the caller's load and this call
          # (double-remove race) — a clean refusal, not a raise.
          no_longer_exists(changeset)

        {:ok, located} ->
          guarded(located, changeset)
      end
    end)
  end

  defp guarded(located, changeset) do
    # get-before-lock is safe: user_id is immutable post-create, so a
    # forged struct cannot decoy the lock target. The guard values come
    # from a SECOND read taken after the lock — the lock is what orders
    # concurrent writers, so post-lock state is the truth (and a
    # concurrent remover's committed delete surfaces here as not-found,
    # also a clean refusal).
    lock_user(located.user_id)

    case Ash.get(UserEmail, changeset.data.id, authorize?: false) do
      # Concurrent-window only: another remover deleted the row and
      # committed between our first get and taking the user lock.
      # ExUnit's single sandbox connection cannot interleave that.
      # coveralls-ignore-start
      {:error, _not_found} ->
        no_longer_exists(changeset)

      # coveralls-ignore-stop

      {:ok, fresh} ->
        decide(fresh, changeset)
    end
  end

  # authorize?: false throughout — invariant checks, same stance as
  # EnforceEmailCap: the action's policy already gated the caller.
  #
  # The invitation guard runs FIRST: an unaccepted invitation's pending
  # row is the invitation's address record (#287) — occupant resolution,
  # the admin surface, and re-invite all ride it. Removing it would
  # orphan the invite (re-invite would mint a second account for the
  # same address), so every remover is refused, admins included; the
  # invitation lifecycle is the only lever (accept it, or re-issue).
  defp decide(fresh, changeset) do
    cond do
      invitation_reservation?(fresh) ->
        Ash.Changeset.add_error(
          changeset,
          field: :address,
          message:
            "is an outstanding invitation's address. The invitation owns it until it is accepted or re-issued"
        )

      # The invariant is about verified addresses: removing a pending
      # row (a typo claim, say) can never drop the user below one
      # verified address.
      fresh.verified_at != nil and last_verified?(fresh) ->
        Ash.Changeset.add_error(
          changeset,
          field: :verified_at,
          message: "is the only verified address. Add and verify another first"
        )

      fresh.is_primary ->
        Ash.Changeset.add_error(
          changeset,
          field: :is_primary,
          message: "is the primary address. Make another address primary first"
        )

      true ->
        changeset
    end
  end

  # The row is pending AND its owner carries an unaccepted invitation
  # (any lifecycle state — pending, withdrawn, expired: retirement
  # keeps the reservation, the frozen-mirror posture). A verified row
  # can never be a reservation: acceptance flips the row verified and
  # stamps invite_accepted_at in the same write.
  defp invitation_reservation?(row) do
    owner = Ash.get!(User, row.user_id, authorize?: false)

    is_nil(row.verified_at) and not is_nil(owner.invited_at) and
      is_nil(owner.invite_accepted_at)
  end

  defp lock_user(user_id) do
    User
    |> Ash.Query.filter(id == ^user_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(authorize?: false)
  end

  defp no_longer_exists(changeset) do
    Ash.Changeset.add_error(
      changeset,
      field: :address,
      message: "address no longer exists"
    )
  end

  defp last_verified?(record) do
    count =
      UserEmail
      |> Ash.Query.filter(
        user_id == ^record.user_id and not is_nil(verified_at) and id != ^record.id
      )
      |> Ash.count!(authorize?: false)

    count == 0
  end
end
