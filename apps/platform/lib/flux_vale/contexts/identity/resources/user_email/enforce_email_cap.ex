defmodule FluxVale.Identity.UserEmail.EnforceEmailCap do
  @moduledoc """
  Caps how many email rows a user may hold (`UserEmail.max_emails_per_user/0`)
  — the add action refuses past the cap. Runs before_action inside the
  create transaction, so the count and the insert commit or roll back
  together.
  """

  use Ash.Resource.Change

  alias FluxVale.Identity.UserEmail

  require Ash.Query

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    cap = UserEmail.max_emails_per_user()

    Ash.Changeset.before_action(changeset, fn changeset ->
      user = Ash.Changeset.get_argument(changeset, :user)

      # authorize?: false is an invariant count, not an authorization
      # question: the action's policy already gated the caller, and the
      # cap must hold regardless of read-policy shape.
      existing =
        UserEmail
        |> Ash.Query.filter(user_id == ^user.id)
        |> Ash.count!(authorize?: false)

      if existing >= cap do
        Ash.Changeset.add_error(
          changeset,
          field: :address,
          message: "too many email addresses (max #{cap})"
        )
      else
        changeset
      end
    end)
  end
end
