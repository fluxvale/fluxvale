defmodule FluxVale.Infrastructure.Instance.ErroredAtBackfill do
  @moduledoc """
  The `errored_at` one-time backfill (infra #182) — the derivation's
  last home. Lives in lib/ rather than only inside the migration so the
  migration and its pinning test run the SAME SQL: migrations are
  `.exs` evaluated by Ecto at runtime, never compiled, so a test cannot
  call into one (the PersonalOwnerBackfill precedent — one algorithm,
  no forked copy).

  The rule: each instance currently in `:error` takes its entry instant
  from the paper trail — the latest `instances_versions` row whose
  `changes` map carries `status: "error"` (changes_only tracking wrote
  one per real to-error transition; the state machine forbids
  re-entering error without leaving, so the latest is THIS episode's
  entry). The `id DESC` tiebreak is the uuid_v7 write-order guard for
  same-microsecond `version_inserted_at` ties. Rows no longer in error
  are never touched (the exit already cleared the stamp post-deploy,
  and an exited episode is not stuck regardless); rows the trail cannot
  date stay NULL — the gauge's `errored_at > cutoff` comparison
  excludes NULL, and an unknown entry time must not page.

  Two entrypoints, one statement: the migration rides
  `execute(sql())` — the migration connection, where the just-added
  column is visible inside its DDL transaction (a bare `Repo.query!`
  there checks out a different pool connection and cannot see the
  uncommitted ALTER). The pinning test rides `run/0`, where the column
  already exists.

  Idempotent: still-error rows re-derive to the same trail instant (the
  trail is append-only history), and every other row fails the
  `status = 'error'` guard.

  Deploy-window residual, accepted: a pod on the old code can land
  `:error` in the seconds while `bin/migrate` runs in the init
  container — its write commits after the backfill's snapshot, and old
  code knows no stamp. The row stays NULL (a one-time UPDATE never
  re-runs) and NULL is gauge-excluded until the episode exits and
  re-enters under the new code, which stamps the re-entry.
  Seconds-wide, bounded, and NULL-conservative by design: an undated
  error can only undercount the gauge, never inflate it.
  """

  alias FluxVale.Repo

  @doc "The backfill statement — one UPDATE over the paper trail's latest to-error version per error row."
  @spec sql :: String.t()
  def sql do
    """
    UPDATE instances AS instance
    SET errored_at = entry.version_inserted_at
    FROM (
      SELECT DISTINCT ON (version_source_id)
        version_source_id, version_inserted_at
      FROM instances_versions
      WHERE changes ->> 'status' = 'error'
      ORDER BY version_source_id, version_inserted_at DESC, id DESC
    ) AS entry
    WHERE instance.id = entry.version_source_id AND instance.status = 'error'
    """
  end

  @spec run :: :ok
  def run do
    Repo.query!(sql())
    :ok
  end
end
