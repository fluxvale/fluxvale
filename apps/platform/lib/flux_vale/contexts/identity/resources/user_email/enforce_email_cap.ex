defmodule FluxVale.Identity.UserEmail.EnforceEmailCap do
  @moduledoc """
  The friendly face of the per-user email cap
  (`UserEmail.max_emails_per_user/0`): the before_action pre-check
  refuses a single over-cap add with a clear error before anything is
  written.

  This hook is NOT the invariant — a hook cannot express one, because
  the rollback guarantee on `Ash.bulk_create` is conditional on opts the
  caller controls (`transaction: false` and `rollback_on_error?: false`
  both persisted an over-cap batch; batch splits left a partial
  success). The invariant lives in the data layer: a deferred constraint
  trigger on `user_emails` (see the `add_user_email_cap_trigger`
  migration) refuses any write — Ash or not — that would exceed the cap.
  """

  use Ash.Resource.Change

  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail

  require Ash.Query

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    cap = UserEmail.max_emails_per_user()

    Ash.Changeset.before_action(changeset, fn changeset ->
      user = Ash.Changeset.get_argument(changeset, :user)

      # Serialize per user: two concurrent adds could both count below the
      # cap and both insert (unique_address can't arbitrate across
      # different addresses). Locking the parent user row makes
      # count-and-insert a per-user critical section (the Instance
      # adopt_* idiom). The deferred cap trigger is the final arbiter if
      # anything still slips through.
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
  end
end
