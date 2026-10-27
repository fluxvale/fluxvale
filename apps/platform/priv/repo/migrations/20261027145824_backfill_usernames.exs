defmodule FluxVale.Repo.Migrations.BackfillUsernames do
  @moduledoc """
  One-time data backfill (#285 T2): existing users get the username a
  signup with their email would derive today. Iterates in created_at
  order so the earliest signer keeps the bare local part; idempotent —
  users with a username are skipped, so a re-run (or a rolling-deploy
  node that already backfilled) never clobbers.

  Shares `DeriveUsername.derive_unique/1` with the Ash change — one
  algorithm, no forked copy. The migrator wraps `up/0` in a Repo
  transaction, and same-process Repo work joins it: the loop's writes
  and the shared probe ride that one transaction, so each backfilled
  username is visible to the next probe and the whole backfill commits
  atomically. A signup concurrent with the backfill can still race a
  claimed name — it fails loudly, the identity index arbitrates, and
  the retry probes the next suffix: provisioning's accepted posture.
  """

  use Ecto.Migration

  alias FluxVale.Identity.User.DeriveUsername
  alias FluxVale.Repo

  def up do
    # Small table, plain loop — no batching machinery (T2).
    for %{id: id, email: email} <- pending_users() do
      username = DeriveUsername.derive_unique(email)

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
      Repo.query!("SELECT id, email FROM users WHERE username IS NULL ORDER BY created_at")

    Enum.map(result.rows, fn [id, email] -> %{id: id, email: email} end)
  end
end
