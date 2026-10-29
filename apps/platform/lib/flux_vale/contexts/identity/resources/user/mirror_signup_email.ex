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

  The same write is the old-pod heal's seam (`write_mirror_row/1`):
  accounts created by pre-T3 pods hold their address in `users.email`
  with no row, and their first post-T3 sign-in (or the seed) writes the
  row this change would have (#285 review P2-3). The heal may reach an
  account that already owns another row — a second address promoted
  primary while the signup address still had none — so the row takes
  `is_primary` only when the account has no primary yet; forcing true
  would collide the partial unique index and wedge the sign-in.
  """

  use Ash.Resource.Change

  alias FluxVale.Identity.UserEmail

  # Ash.Query.filter is a macro
  require Ash.Query

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      case write_mirror_row(user) do
        {:ok, _row} ->
          {:ok, user}

        # Rolls the whole create back — a user without its mirror row must
        # not exist (every account is table-backed from birth).
        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Writes the account's verified mirror row for `user.email` — the
  create path's own post-insert step, exposed so the old-pod heals
  (VerifyAuthCode's collision arm, the seed admin) write exactly the row
  the create would have: one writer for the mirror shape, so the two
  paths cannot fork.

  Primary only when the account has no primary row yet. The create
  path's account is brand-new (always none); a healed account may own
  one already — a second address promoted while the signup address had
  no row — and forcing true would collide the partial unique index
  (at-most-one primary per user), failing the heal and wedging the
  address (review round 2, P1). authorize?: false — the caller is a
  system seam (a burned code, or the bootstrap seed).
  """
  @spec write_mirror_row(FluxVale.Identity.User.t()) ::
          {:ok, UserEmail.t()} | {:error, term()}
  def write_mirror_row(user) do
    UserEmail
    |> Ash.Changeset.for_create(:add, %{address: user.email, user: %{id: user.id}})
    # force_change_attribute: for_create has already validated, and the
    # plain setter refuses after that point — the values are literals
    # the create already knows (same escape SetPrimary's hook makes)
    |> Ash.Changeset.force_change_attribute(:verified_at, DateTime.utc_now())
    # is_primary is decided in a before_action, not here: the hook runs
    # after EnforceEmailCap's FOR UPDATE lock on the user row, inside
    # the transaction, so takes_primary?/1 serializes with SetPrimary
    # (round-3 P2: in argument position the count ran before the
    # transaction opened and lost the race to a concurrent promotion)
    |> Ash.Changeset.before_action(fn changeset ->
      Ash.Changeset.force_change_attribute(changeset, :is_primary, takes_primary?(user))
    end)
    |> Ash.create(authorize?: false)
  end

  # authorize?: false — an invariant count, not an authorization
  # question (the caller is the system seam; same stance as
  # EnforceEmailCap). Called from the before_action above, so the read
  # runs inside the create transaction, after EnforceEmailCap's FOR
  # UPDATE lock on the user row. That serializes the count-and-insert
  # with every writer that takes the same user-row lock — SetPrimary
  # (its hook locks before promoting) and the cap itself. It does NOT
  # serialize with a writer that promotes by other means (raw SQL, an
  # operator UPDATE, the T1 backfill's shape): such a writer can still
  # commit between this count and the insert, and the at-most-one-
  # primary partial index then refuses the insert — the heal returns
  # {:error, :address_unresolved}, atom-shaped, and a retry heals.
  # The index is the arbiter for ALL writers; the lock is the
  # serializer for the sanctioned ones (review round 4, P2).
  #
  # Ash.count! raises on DB failure. Ash's action boundary
  # (deps/ash/lib/ash/actions/create/create.ex) re-raises it as
  # Ash.Error.Unknown — it does NOT become this create's
  # {:error, _} return, so a DB failure escapes write_mirror_row/1's
  # spec and call/2's atom contract (pre-existing; round-4 review
  # P3-1). Hence no value-shaped arm: the {:error, _} arm this
  # replaced was dead code — Ash.count/2 raises on the same classes.
  defp takes_primary?(user) do
    count =
      UserEmail
      |> Ash.Query.filter(user_id == ^user.id and is_primary)
      |> Ash.count!(authorize?: false)

    count == 0
  end
end
