defmodule FluxVale.Identity.UserEmail.EnforceEmailCap do
  @moduledoc """
  Caps how many email rows a user may hold (`UserEmail.max_emails_per_user/0`)
  — the add action refuses past the cap.

  Two checks, because neither alone can express the cap:

  - `before_action` counts existing rows pre-insert — refuses a single
    add past the cap before anything is written. It cannot see bulk
    creates: Ash runs every before_action (each counting the untouched
    table) before ONE batched INSERT, so every row in a batch counts 0.
  - `after_action` re-counts post-insert and refuses when the end state
    exceeds the cap. Bulk creates run each batch inside a transaction
    with `rollback_on_error?: true` by default, so the over-cap batch
    fails loudly as a whole — a partial insert cannot survive.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail

  require Ash.Query

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    cap = UserEmail.max_emails_per_user()

    changeset =
      Ash.Changeset.before_action(changeset, fn changeset ->
        user = Ash.Changeset.get_argument(changeset, :user)

        # Serialize per user: two concurrent adds could both count below the
        # cap and both insert (unique_address can't arbitrate across
        # different addresses). Locking the parent user row makes
        # count-and-insert a per-user critical section (the Instance
        # adopt_* idiom).
        User
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.Query.lock(:for_update)
        |> Ash.read_one!(authorize?: false)

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

    Ash.Changeset.after_action(changeset, fn changeset, result ->
      user = Ash.Changeset.get_argument(changeset, :user)

      # authorize?: false — invariant count, same stance as the pre-check.
      total =
        UserEmail
        |> Ash.Query.filter(user_id == ^user.id)
        |> Ash.count!(authorize?: false)

      if total > cap do
        {:error,
         InvalidAttribute.exception(
           field: :address,
           message: "too many email addresses (max #{cap})"
         )}
      else
        {:ok, result}
      end
    end)
  end
end
