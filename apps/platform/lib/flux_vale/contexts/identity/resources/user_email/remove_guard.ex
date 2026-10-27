defmodule FluxVale.Identity.UserEmail.RemoveGuard do
  @moduledoc """
  Guards address removal: the primary cannot go (switch first), and a
  user's last verified address cannot go either — every account keeps at
  least one proven address. Both checks run before_action inside the
  destroy transaction.
  """

  use Ash.Resource.Change

  alias FluxVale.Identity.UserEmail

  require Ash.Query

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      record = changeset.data

      cond do
        record.is_primary ->
          Ash.Changeset.add_error(
            changeset,
            field: :is_primary,
            message: "is the primary address — make another address primary first"
          )

        last_verified?(record) ->
          Ash.Changeset.add_error(
            changeset,
            field: :verified_at,
            message: "is the only verified address — add and verify another first"
          )

        true ->
          changeset
      end
    end)
  end

  # authorize?: false — invariant count, same stance as EnforceEmailCap.
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
