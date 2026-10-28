defmodule FluxVale.Identity.User.MirrorSignupEmail do
  @moduledoc """
  Writes the account's first `user_emails` row at create (#285 T3 §5):
  the signup address lands VERIFIED (the burned code proved it on the
  JIT path — the same end state the T1 backfill gave every pre-existing
  user) and PRIMARY. From its first commit, the account is
  table-backed: sign-in resolves through `user_emails`.

  `users.email` stays written too — it is a FROZEN mirror for old pods
  during rolling deploys (see the attribute comment on `User`); the
  follow-up contract release drops the column.

  System path, one insert: the row rides the `:add` action so address
  validation and the cap hold, with `verified_at`/`is_primary` set
  programmatically — calling `mark_verified` + `set_primary` would be
  two more nested actions to produce values the create already knows.
  authorize?: false: the create's own policy gated the caller; a brand
  new account's first address raises no actor question.
  """

  use Ash.Resource.Change

  alias FluxVale.Identity.UserEmail

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      mirror(user)
    end)
  end

  # An address held as another account's PENDING claim refuses the
  # create (unique_address): the claim exists, the address is taken —
  # loud, like provisioning's failures. The JIT sign-in path deletes
  # the superseded claim before provisioning (VerifyAuthCode), so it
  # never sees this.
  defp mirror(user) do
    case create_row(user) do
      {:ok, _row} ->
        {:ok, user}

      # Rolls the whole create back — a user without its mirror row must
      # not exist (every account is table-backed from birth).
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_row(user) do
    UserEmail
    |> Ash.Changeset.for_create(:add, %{address: user.email, user: %{id: user.id}})
    # force_change_attribute: for_create has already validated, and the
    # plain setter refuses after that point — the values are literals
    # the create already knows (same escape SetPrimary's hook makes)
    |> Ash.Changeset.force_change_attribute(:verified_at, DateTime.utc_now())
    |> Ash.Changeset.force_change_attribute(:is_primary, true)
    |> Ash.create(authorize?: false)
  end
end
