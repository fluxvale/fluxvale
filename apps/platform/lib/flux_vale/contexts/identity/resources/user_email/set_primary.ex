defmodule FluxVale.Identity.UserEmail.SetPrimary do
  @moduledoc """
  Makes this row the user's one primary address: promotes it and demotes
  the user's other primaries inside the same transaction (before_action +
  the action's own write). The partial unique index stays the final
  arbiter if a concurrent write slips past the read.
  """

  use Ash.Resource.Change

  alias FluxVale.Identity.UserEmail

  require Ash.Query

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      record = changeset.data

      if record.verified_at == nil do
        # A pending address cannot become primary.
        Ash.Changeset.add_error(
          changeset,
          field: :verified_at,
          message: "must be verified before it can be made primary"
        )
      else
        # authorize?: false — same invariant-count stance as EnforceEmailCap:
        # sibling demotion is the action's own job, not a policy question.
        UserEmail
        |> Ash.Query.filter(user_id == ^record.user_id and is_primary and id != ^record.id)
        |> Ash.read!(authorize?: false)
        |> Enum.each(&Ash.update!(&1, %{}, action: :unset_primary, authorize?: false))

        # force_change_attribute: the hook runs after validation, and the
        # plain setter warns (and is skipped) there — the value is a
        # literal, nothing to validate.
        Ash.Changeset.force_change_attribute(changeset, :is_primary, true)
      end
    end)
  end
end
