defmodule FluxVale.Feedback.Post.RejectReferencedOriginal do
  @moduledoc """
  Guard on `:destroy` — a post other posts point at via `duplicate_of_id`
  must refuse with a field-scoped error, not an Ecto constraint crash:
  the day-one moderation surface is AshAdmin (ADR-0026 Am. 1), and an
  admin clicking destroy on a referenced original deserves the reason.

  The probe runs inside the destroy transaction (a before_action) and
  reads `authorize?: false` — an invariant check, the action's policy
  already gated the caller (the SetPrimary stance). The `duplicate_of`
  FK stays the race backstop: a duplicate planted between probe and
  delete still dies loudly on the constraint.
  """

  use Ash.Resource.Change

  alias FluxVale.Feedback.Post

  require Ash.Query

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &reject_if_referenced/1)
  end

  defp reject_if_referenced(changeset) do
    referenced? =
      Post
      |> Ash.Query.filter(duplicate_of_id == ^changeset.data.id)
      |> Ash.exists?(authorize?: false)

    if referenced? do
      Ash.Changeset.add_error(
        changeset,
        field: :duplicate_of_id,
        message: "is pointed at by a duplicate post"
      )
    else
      changeset
    end
  end

  @impl Ash.Resource.Change
  def atomic?, do: false
end
