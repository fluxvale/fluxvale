defmodule FluxVale.Accounts.Organization.PersonalOwnerBackfill do
  @moduledoc """
  The personal-org marker's one-time backfill (#408) — the earliest-owned
  derivation's last home. Lives in lib/ rather than only inside the
  migration so the migration and its pinning test run the SAME SQL:
  migrations are `.exs` evaluated by Ecto at runtime, never compiled, so
  a test cannot call into one (the DeriveUsername precedent — one
  algorithm, no forked copy).

  The rule is exactly the derivation `PersonalOrgForUser` retired: each
  user's earliest-created owned org (owner memberships, org created_at
  then id) is the candidate; when one org is the earliest-owned for
  several users (the seeded two-owner shape), the earliest-joining
  membership wins (membership created_at, then user_id) and the other
  users keep NO personal org — their `PersonalOrgForUser` reads `:none`,
  and the switcher pill degrades to the bare glyph (#308's split-state
  stance).

  Two entrypoints, one statement: the migration rides `execute(sql())` —
  the migration connection, where the just-added column is visible inside
  its DDL transaction (a bare `Repo.query!` there checks out a different
  pool connection and cannot see the uncommitted ALTER). The pinning test
  rides `run/0`, where the column already exists. Idempotent-by-timing,
  like every migration: Ecto records the version, so this never re-runs.
  The winners CTE names each org at most once and each user at most once,
  so the `unique_personal_owner` index cannot trip.
  """

  alias FluxVale.Repo

  # Per-user earliest-owned candidate, then per-org earliest-joining
  # winner, one UPDATE.
  @doc "The backfill statement — one UPDATE over two CTEs."
  @spec sql :: String.t()
  def sql do
    """
    WITH candidates AS (
      SELECT DISTINCT ON (memberships.user_id)
        organizations.id AS org_id,
        memberships.user_id,
        memberships.created_at AS joined_at
      FROM memberships
      JOIN organizations ON organizations.id = memberships.organization_id
      WHERE memberships.role = 'owner'
      ORDER BY memberships.user_id, organizations.created_at, organizations.id
    ),
    winners AS (
      SELECT DISTINCT ON (org_id) org_id, user_id
      FROM candidates
      ORDER BY org_id, joined_at, user_id
    )
    UPDATE organizations
    SET personal_owner_id = winners.user_id
    FROM winners
    WHERE organizations.id = winners.org_id
    """
  end

  @spec run :: :ok
  def run do
    Repo.query!(sql())
    :ok
  end
end
