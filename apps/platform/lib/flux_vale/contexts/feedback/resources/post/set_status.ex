defmodule FluxVale.Feedback.Post.SetStatus do
  @moduledoc """
  The status workflow's guard + audit stamps (ADR-0026 §1), guarded in
  BOTH directions:

  - an off-`:duplicate` move force-clears `duplicate_of_id` — a reopened
    post must not keep its pointer, and a caller passing the pointer on
    an off-duplicate move must not plant one;
  - a `:duplicate` move requires a pointer at another post (no
    self-reference) whose target, read FRESH inside the transaction, is
    not itself a duplicate — duplicates point at originals, depth one,
    no chains. The unreadable target fails CLOSED (the move is refused;
    the `duplicate_of` FK answers dangling ids at the DB too).

  `duplicate_of_id` is read with `Ash.Changeset.get_attribute/2`, which
  falls back to the loaded row: re-asserting `:duplicate` without
  re-passing the pointer keeps the CURRENT row's pointer — the move is
  idempotent, which the DB CHECK (`status_matches_duplicate_of`) mirrors
  row-locally.

  Every status move stamps WHO and WHEN (`status_changed_by_user_id` /
  `status_changed_at`) for the author-notification slice. before_action:
  inside the update's transaction, so guard and write are one unit.
  """

  use Ash.Resource.Change

  alias FluxVale.Feedback.Post

  @impl Ash.Resource.Change
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, &guard_and_stamp(&1, Map.get(context, :actor)))
  end

  defp guard_and_stamp(changeset, actor) do
    status = Ash.Changeset.get_argument(changeset, :status)
    duplicate_of_id = Ash.Changeset.get_attribute(changeset, :duplicate_of_id)

    cond do
      status != :duplicate ->
        # Clear the pointer on the way out of :duplicate — the row-local
        # CHECK requires status and pointer to move together. The clear
        # rides atomic_update because its {:ok, nil} branch Map.puts the
        # attribute directly, bypassing force_change_attribute/3's
        # no-op drop of forced nils (which only fires when the row's
        # value is already nil). The UPDATE itself is a regular change.
        changeset
        |> Ash.Changeset.atomic_update(:duplicate_of_id, nil)
        |> stamp(actor)

      is_nil(duplicate_of_id) ->
        Ash.Changeset.add_error(
          changeset,
          field: :duplicate_of_id,
          message: "is required when marking a post duplicate"
        )

      duplicate_of_id == changeset.data.id ->
        Ash.Changeset.add_error(
          changeset,
          field: :duplicate_of_id,
          message: "cannot reference itself"
        )

      true ->
        check_target(changeset, duplicate_of_id, actor)
    end
  end

  # The target is read fresh inside the transaction: a concurrent move
  # to :duplicate cannot slip between the read and the write, and a
  # read failure refuses the move (fail closed) instead of planting a
  # chain. authorize?: false — an invariant check, the action's policy
  # already gated the caller (the SetPrimary stance).
  defp check_target(changeset, duplicate_of_id, actor) do
    case Ash.get(Post, duplicate_of_id, authorize?: false) do
      {:ok, %{status: :duplicate}} ->
        Ash.Changeset.add_error(
          changeset,
          field: :duplicate_of_id,
          message: "cannot reference a post that is itself a duplicate"
        )

      {:ok, _original} ->
        stamp(changeset, actor)

      # Dangling id or unreadable row — refuse loudly either way; the FK
      # answers the dangling case at the DB as the race backstop.
      {:error, _reason} ->
        Ash.Changeset.add_error(
          changeset,
          field: :duplicate_of_id,
          message: "must reference an existing post that is not a duplicate"
        )
    end
  end

  # Audit literals, nothing to validate — force_change_attribute (the
  # hook runs after validation; the plain setter warns and is skipped
  # there). The action is admin-gated, so callers carry an actor; the
  # nil arm only serves a no-actor system caller.
  defp stamp(changeset, actor) do
    changeset
    |> Ash.Changeset.force_change_attribute(:status_changed_by_user_id, actor_id(actor))
    |> Ash.Changeset.force_change_attribute(:status_changed_at, DateTime.utc_now())
  end

  defp actor_id(nil), do: nil
  defp actor_id(actor), do: actor.id

  @impl Ash.Resource.Change
  def atomic?, do: false
end
