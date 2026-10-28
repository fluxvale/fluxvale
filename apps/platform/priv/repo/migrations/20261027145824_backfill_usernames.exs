defmodule FluxVale.Repo.Migrations.BackfillUsernames do
  @moduledoc """
  One-time data backfill (#285 T2). ADR-00013 rule 3: backfills are
  batched release tasks or background jobs, never inline migrations —
  this one rides Amendment 1's pre-launch carve-out instead (rows are
  disposable until the first production deploy; the M6 checkout train
  is the target). Revisit trigger: move the sweep out of the migration
  before M6.

  Iterates users in `created_at, id` order (UUIDv7 ties break
  consistently) so the earliest signer keeps the bare local part, and
  is idempotent — users with a username are skipped. Ecto records the
  version, so this never re-runs: users created by old pods during the
  rolling window keep username NULL (that is why the column is nullable
  and /me pins the null arm), and the follow-up contract release must
  sweep those stragglers BEFORE its NOT NULL — a hard dependency on the
  drop-mirror issue.

  Shares `DeriveUsername.derive_unique/2` with the Ash change — one
  algorithm, no forked copy — but injects a raw-SQL probe closure: an
  Ash read would SELECT every current User attribute and break
  fresh-DB replay the moment the resource outgrows this frozen
  migration. The migrator wraps `up/0` in a Repo transaction, and
  same-process Repo work joins it: the loop's writes and the probe
  ride that one transaction, so each backfilled username is visible to
  the next probe and the whole backfill commits atomically. A signup
  concurrent with the backfill can still race a claimed name — it
  fails loudly, the identity index arbitrates, and the retry probes
  the next suffix: provisioning's accepted posture.
  """

  use Ecto.Migration

  alias FluxVale.Identity.User.DeriveUsername
  alias FluxVale.Repo

  def up do
    # Schema-free probe: this column and nothing else — the migration is
    # frozen, so it must not lean on Ash reads that grow with the
    # resource (ADR-00013's undefined-column replay failure).
    free? = fn candidate ->
      result = Repo.query!("SELECT 1 FROM users WHERE username = $1", [candidate])
      result.num_rows == 0
    end

    # Small table, plain loop — no batching machinery (T2).
    for %{id: id, email: email} <- pending_users() do
      username = DeriveUsername.derive_unique(email, free?)

      Repo.query!("UPDATE users SET username = $1 WHERE id = $2", [username, id])
    end
  end

  def down do
    # Data backfill: down restores nothing — add_users_username's down
    # drops the column wholesale.
    :ok
  end

  defp pending_users do
    result =
      Repo.query!("SELECT id, email FROM users WHERE username IS NULL ORDER BY created_at, id")

    Enum.map(result.rows, fn [id, email] -> %{id: id, email: email} end)
  end
end
