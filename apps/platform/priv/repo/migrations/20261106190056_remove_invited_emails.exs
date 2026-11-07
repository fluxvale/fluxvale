defmodule FluxVale.Repo.Migrations.RemoveInvitedEmails do
  @moduledoc """
  Drops the retired invited-email gate table (#502). The gate is dead
  code: invites pre-provision the User directly, and no lib/ caller of
  Ops.InvitedEmails remains.

  Destructive by design, sanctioned pre-launch by ADR-0013 Am. 1's
  carve-out: no data migration, the PA ruled the data wipes before
  launch anyway. `down` recreates the table verbatim (the #478 create
  shape) for rollback sanity.
  """

  use Ecto.Migration

  def up do
    # The unique address index goes with the table (Postgres drops a
    # table's indexes with it).
    drop(table(:invited_emails))
  end

  def down do
    create table(:invited_emails, primary_key: false) do
      add(:id, :uuid, null: false, primary_key: true)

      add(:created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:address, :citext, null: false)
      add(:revoked_at, :utc_datetime_usec)
    end

    create(unique_index(:invited_emails, [:address], name: "invited_emails_unique_address_index"))
  end
end
