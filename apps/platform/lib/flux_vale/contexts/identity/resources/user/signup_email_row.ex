defmodule FluxVale.Identity.User.SignupEmailRow do
  @moduledoc """
  Writes the account's first `user_emails` row at create (#285 T3 §5,
  #287): the signup address — the :email ARGUMENT, there is no column
  anymore — lands VERIFIED (the burned code proved it on the JIT path)
  and PRIMARY. From its first commit, the account is table-backed:
  sign-in resolves through `user_emails`.

  System path, one insert: the row rides the `:add` action so address
  validation and the cap hold, with `verified_at`/`is_primary` set
  programmatically. authorize?: false: the create's own policy gated
  the caller; a brand new account's first address raises no actor
  question.

  The account is brand-new (no rows, no primary), so `is_primary` is a
  literal true — the invite-era conditional that once lived here (the
  old-pod heal could reach an account that already owned a primary)
  died with the heal paths and the column (#287): this change only
  ever runs on :create.
  """

  use Ash.Resource.Change

  alias FluxVale.Identity.UserEmail

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    address = Ash.Changeset.get_argument(changeset, :email)

    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      case write_row(user, address) do
        {:ok, _row} ->
          {:ok, user}

        # Rolls the whole create back — a user without its signup row
        # must not exist (every account is table-backed from birth).
        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Writes the verified-primary signup row for `address` — the create
  path's own post-insert step. Primary is unconditional (see the
  moduledoc: brand-new account). authorize?: false — the caller is a
  system seam (the interaction-bypassed JIT create, or the bootstrap
  seed).
  """
  @spec write_row(FluxVale.Identity.User.t(), String.t() | Ash.CiString.t()) ::
          {:ok, UserEmail.t()} | {:error, term()}
  def write_row(user, address) do
    UserEmail
    |> Ash.Changeset.for_create(:add, %{address: address, user: %{id: user.id}})
    # force_change_attribute: for_create has already validated, and the
    # plain setter refuses after that point — the values are literals
    # the create already knows (same escape SetPrimary's hook makes)
    |> Ash.Changeset.force_change_attribute(:verified_at, DateTime.utc_now())
    |> Ash.Changeset.force_change_attribute(:is_primary, true)
    |> Ash.create(authorize?: false)
  end
end
