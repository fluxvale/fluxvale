defmodule FluxVale.Repo.Migrations.AddPersonalOwnerMarker do
  @moduledoc """
  The personal-org marker (#408 slice 1): a nullable `personal_owner_id`
  on organizations, unique-indexed — the explicit fact "which org is a
  user's account-surface org" replaces the earliest-owned derivation
  `PersonalOrgForUser` used to run live. Null marks a team org; Postgres
  unique indexes treat NULLs as distinct, so team orgs never conflict.

  The up-direction carries the one-time backfill (the derivation's last
  home — the SQL lives in
  `FluxVale.Accounts.Organization.PersonalOwnerBackfill`, shared with
  its pinning test). ADR-00013 rule 3 says backfills are never inline
  migrations; this rides Amendment 1's pre-launch carve-out like the
  other day-one backfills — rows are disposable until the first
  production deploy, and #408's owner-approved design pins it here.
  Revisit trigger: move the sweep out of the migration before M6.

  Rolling-window gap, accepted: an old-pod provisioning that commits
  after the backfill's snapshot leaves that org unmarked, and a
  `User.create` never re-runs — pre-launch (Amendment 1) the rows are
  disposable, and the docs/deployment.md operator heal re-provisions
  (at most one extra org for the straggler). The M6 batched sweep
  re-runs, which an inline migration never can.

  Coverage note: migrations are `.exs` loaded by Ecto at runtime — they
  never enter the compiled coverage trace, so no exclusion is needed.
  """

  use Ecto.Migration

  alias FluxVale.Accounts.Organization.PersonalOwnerBackfill

  def up do
    alter table(:organizations) do
      add(:personal_owner_id, :uuid)
    end

    create(
      unique_index(:organizations, [:personal_owner_id],
        name: "organizations_unique_personal_owner_index"
      )
    )

    # The earliest-owned derivation, run once: `execute` rides the
    # migration connection (see the backfill's moduledoc for why not a
    # bare Repo call), inside the migration's own DDL transaction.
    execute(PersonalOwnerBackfill.sql())
  end

  def down do
    drop_if_exists(
      unique_index(:organizations, [:personal_owner_id],
        name: "organizations_unique_personal_owner_index"
      )
    )

    alter table(:organizations) do
      remove(:personal_owner_id)
    end
  end
end
