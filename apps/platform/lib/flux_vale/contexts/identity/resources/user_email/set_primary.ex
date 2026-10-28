defmodule FluxVale.Identity.UserEmail.SetPrimary do
  @moduledoc """
  Makes this row the user's one primary address: promotes it and demotes
  the user's other primaries inside the same transaction (before_action +
  the action's own write). The partial unique index stays the final
  arbiter if a concurrent write slips past the read.
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
          # The row vanished between the caller's load and this call —
          # a clean refusal, not a raise.
          no_longer_exists(changeset)

        {:ok, located} ->
          guarded(located, changeset)
      end
    end)
  end

  defp guarded(located, changeset) do
    # get-before-lock is safe: user_id is immutable post-create, so a
    # forged struct cannot decoy the lock target. The verified_at
    # decision comes from a SECOND read taken after the lock — the lock
    # is what orders concurrent writers, so post-lock state is the truth
    # (a forged in-memory verified_at, or a stale struct loaded before a
    # concurrent verify, cannot promote a pending row).
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
        promote(fresh, changeset)
    end
  end

  # authorize?: false throughout — invariant checks, same stance as
  # EnforceEmailCap: the action's policy already gated the caller.
  defp promote(fresh, changeset) do
    if fresh.verified_at == nil do
      # A pending address cannot become primary.
      Ash.Changeset.add_error(
        changeset,
        field: :verified_at,
        message: "must be verified before it can be made primary"
      )
    else
      UserEmail
      |> Ash.Query.filter(user_id == ^fresh.user_id and is_primary and id != ^fresh.id)
      |> Ash.read!(authorize?: false)
      |> Enum.each(&Ash.update!(&1, %{}, action: :unset_primary, authorize?: false))

      # force_change_attribute: the hook runs after validation, and the
      # plain setter warns (and is skipped) there — the value is a
      # literal, nothing to validate.
      Ash.Changeset.force_change_attribute(changeset, :is_primary, true)
    end
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
end
