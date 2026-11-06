defmodule FluxVale.Repo.Migrations.AddInstanceAllocationSnapshots do
  @moduledoc """
  The allocation/pricing audit trail (#493): one append-only row per
  allocation era of an instance, plus the partial unique index holding
  "at most one open era per instance", plus the backfill minting era 1
  for every pre-#493 instance from its create-time values.
  """

  use Ecto.Migration

  def up do
    create table(:instance_allocation_snapshots, primary_key: false) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:cpu_cores, :decimal)
      add(:memory_mb, :bigint)
      add(:storage_gb, :bigint)
      add(:monthly_cents, :bigint)
      add(:stopped_monthly_cents, :bigint)
      add(:effective_from, :utc_datetime_usec, null: false)
      add(:superseded_at, :utc_datetime_usec)

      add(:created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(
        :instance_id,
        references(:instances,
          column: :id,
          name: "instance_allocation_snapshots_instance_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :size_id,
        references(:pricing_sizes,
          column: :id,
          name: "instance_allocation_snapshots_size_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
    end

    create(index(:instance_allocation_snapshots, [:instance_id]))

    # One open era per instance — the boundary the resize's
    # supersede-then-append cycle maintains (a second open row would be
    # ambiguous audit history).
    create(
      index(:instance_allocation_snapshots, [:instance_id],
        name: "instance_allocation_snapshots_one_open_per_instance",
        unique: true,
        where: "superseded_at IS NULL"
      )
    )

    # ----------------------------------------------------------------
    # Backfill: pre-#493 rows snapshot at create — one era-1 row per
    # existing instance from its create-time values, effective from the
    # instance's own created_at (the era the row has been living in all
    # along). Nothing supersedes it; the next resize closes it.
    #
    # Pre-launch stance (owner ruling, relayed 2026-11-06): ALL data is
    # wiped at launch, so this never runs on production data and no
    # migration is owed — it keeps dev/staging trails coherent until
    # the wipe. The append path tolerates a missing era 1 regardless
    # (its drift arm).
    #
    # ids are uuidv7() — PG18 native, the "non-Ash writer" source
    # ADR-0032 rule 3 reserves for exactly this case (app-side
    # generation is for action writes; a backfill's ids are
    # insert-order-irrelevant).
    # ----------------------------------------------------------------
    execute("""
    INSERT INTO instance_allocation_snapshots
      (id, instance_id, cpu_cores, memory_mb, storage_gb, size_id,
       monthly_cents, stopped_monthly_cents, effective_from, created_at, updated_at)
    SELECT uuidv7(), i.id, i.cpu_cores, i.memory_mb, i.storage_gb, i.size_id,
       i.grandfathered_monthly_cents, i.grandfathered_stopped_monthly_cents,
       i.created_at, now(), now()
    FROM instances i
    """)
  end

  def down do
    drop_if_exists(
      index(:instance_allocation_snapshots, [:instance_id],
        name: "instance_allocation_snapshots_one_open_per_instance"
      )
    )

    drop_if_exists(index(:instance_allocation_snapshots, [:instance_id]))

    drop(constraint(:instance_allocation_snapshots, "instance_allocation_snapshots_size_id_fkey"))

    drop(
      constraint(
        :instance_allocation_snapshots,
        "instance_allocation_snapshots_instance_id_fkey"
      )
    )

    drop(table(:instance_allocation_snapshots))
  end
end
