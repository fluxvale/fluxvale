defmodule FluxVale.Repo.Migrations.AddAccessDomains do
  @moduledoc """
  Access domains (ADR-0040 S1): `access_domains` + `instance_hostnames`,
  plus the backfill both tables need on day one — every existing org
  gets its `:platform` domain row (the `instances_base_domain`, born
  `:verified` — the fleet wildcard already covers it) and every existing
  instance gets its default hostname (`label = slug`) on that row.

  ADR-00013 rule 3 says backfills are never inline migrations; this
  rides Am. 1's pre-launch carve-out (dev/staging rows are disposable
  until the first production deploy, M6), same as the user-emails
  backfill. Revisit trigger: move it out before M6.

  Idempotent by construction: both inserts are anti-joins against the
  tables' unique identities, so a re-run inserts nothing.

  Coverage note: migrations are `.exs` loaded by Ecto at runtime — they
  never enter the compiled coverage trace, so no exclusion is needed.
  """

  use Ecto.Migration

  def up do
    create table(:access_domains, primary_key: false) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:domain, :text, null: false)
      add(:kind, :text, null: false)
      add(:state, :text, null: false, default: "pending")
      add(:cert_secret_ref, :text)

      add(:registered_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(
        :organization_id,
        references(:organizations,
          column: :id,
          name: "access_domains_organization_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :restrict
        ),
        null: false
      )
    end

    create(
      unique_index(:access_domains, [:organization_id, :domain],
        name: "access_domains_unique_org_domain_index"
      )
    )

    create table(:instance_hostnames, primary_key: false) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:label, :text, null: false)

      add(:created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(
        :instance_id,
        references(:instances,
          column: :id,
          name: "instance_hostnames_instance_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :access_domain_id,
        references(:access_domains,
          column: :id,
          name: "instance_hostnames_access_domain_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :restrict
        ),
        null: false
      )
    end

    create(
      unique_index(:instance_hostnames, [:access_domain_id, :label],
        name: "instance_hostnames_unique_label_per_domain_index"
      )
    )

    # ----------------------------------------------------------------
    # Backfill (see the moduledoc).
    #
    # The base domain comes from the app's config AT MIGRATION-RUN TIME,
    # read here in Elixir — not a module attribute, which would freeze
    # the compile-time value and miss a runtime.exs override (a staging
    # env with INSTANCES_BASE_DOMAIN set must backfill the staging
    # domain). Interpolating a config value into SQL is safe: it is
    # ops-controlled input, never user data.
    #
    # ids are uuidv7() — PG18 native, the "non-Ash writer" source
    # ADR-00032 rule 3 reserves for exactly this case.
    # ----------------------------------------------------------------
    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)

    execute("""
    INSERT INTO access_domains
      (id, organization_id, domain, kind, state, registered_at, created_at, updated_at)
    SELECT uuidv7(), o.id, '#{base_domain}', 'platform', 'verified', now(), now(), now()
    FROM organizations o
    WHERE NOT EXISTS (
      SELECT 1 FROM access_domains d
      WHERE d.organization_id = o.id AND d.domain = '#{base_domain}'
    )
    """)

    # The JOIN drops instances with no organization_id (system-created
    # rows): a hostname is scoped by the org's platform row, so an
    # org-less instance has nothing to point at — its later lanes own it.
    execute("""
    INSERT INTO instance_hostnames
      (id, instance_id, access_domain_id, label, created_at)
    SELECT uuidv7(), i.id, d.id, i.slug, now()
    FROM instances i
    JOIN access_domains d
      ON d.organization_id = i.organization_id
      AND d.kind = 'platform'
      AND d.domain = '#{base_domain}'
    WHERE NOT EXISTS (
      SELECT 1 FROM instance_hostnames h
      WHERE h.access_domain_id = d.id AND h.label = i.slug
    )
    """)
  end

  def down do
    drop(constraint(:instance_hostnames, "instance_hostnames_access_domain_id_fkey"))

    drop(constraint(:instance_hostnames, "instance_hostnames_instance_id_fkey"))

    drop_if_exists(
      unique_index(:instance_hostnames, [:access_domain_id, :label],
        name: "instance_hostnames_unique_label_per_domain_index"
      )
    )

    drop(table(:instance_hostnames))

    drop(constraint(:access_domains, "access_domains_organization_id_fkey"))

    drop_if_exists(
      unique_index(:access_domains, [:organization_id, :domain],
        name: "access_domains_unique_org_domain_index"
      )
    )

    drop(table(:access_domains))
  end
end
