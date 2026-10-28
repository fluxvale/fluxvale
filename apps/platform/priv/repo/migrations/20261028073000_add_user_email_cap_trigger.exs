defmodule FluxVale.Repo.Migrations.AddUserEmailCapTrigger do
  @moduledoc """
  Data-layer arbiter for the per-user email cap (identity lane #285):
  a deferred constraint trigger refuses any write — Ash or not, bulk or
  single, whatever transaction opts the caller picks — that would leave a
  user with more than #{FluxVale.Identity.UserEmail.max_emails_per_user()}
  `user_emails` rows.

  Why a trigger: changeset hooks cannot express a hard cap. The cap's
  rollback guarantee was conditional on bulk opts the CALLER controls
  (`transaction: false` persisted 8 rows; `rollback_on_error?: false`
  persisted 8; `batch_size: 2` left a partial success) — all three
  verified against the hook-based version. The hook that remains on the
  resource is a friendly-error pre-check, not the invariant.

  Deferred (INITIALLY DEFERRED) so the check fires at statement/commit
  end: it sees same-statement siblings (a multi-row INSERT of 8 counts
  8), and autocommit batch splits each land under the cap — an aborting
  batch takes only itself down; committed prior batches stay.

  Maintenance notes:

  - The cap value is hardcoded in the SQL below — a deliberate twin of
    `FluxVale.Identity.UserEmail.max_emails_per_user/0` (the DSL constant
    cannot parametrize raw SQL). Bump both together or the resource and
    the arbiter disagree.
  - `mix ash.codegen --check` diffs resource snapshots against generated
    migrations; it cannot see this hand-written trigger. This migration
    is the trigger's only source of truth.
  """

  use Ecto.Migration

  @cap FluxVale.Identity.UserEmail.max_emails_per_user()

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION fluxvale_user_email_cap() RETURNS trigger AS $$
    BEGIN
      -- Deferred per-row: NEW and any same-statement siblings are already
      -- visible when this fires, so count includes them.
      IF (SELECT count(*) FROM user_emails WHERE user_id = NEW.user_id) > #{@cap} THEN
        RAISE EXCEPTION 'too many email addresses (max #{@cap})'
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER user_emails_cap_trigger
    AFTER INSERT ON user_emails
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION fluxvale_user_email_cap();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS user_emails_cap_trigger ON user_emails;")
    execute("DROP FUNCTION IF EXISTS fluxvale_user_email_cap();")
  end
end
