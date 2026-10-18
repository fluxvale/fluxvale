defmodule FluxVale.Pricing.TaxRate do
  @moduledoc """
  A dated VAT rate for one jurisdiction (ADR-0029 Am. 3 gate 2, #138):
  `country` (2-letter code), optional `state` (US state code; nil is
  country-wide), `rate_bp` (integer basis points, 20% = 2000), and
  `effective_from` — the boundary that starts the rate. There is no
  `effective_to`: the next `effective_from` for the same jurisdiction
  supersedes it, and a checkout resolves the latest row at or before
  the charge time (`Pricing.resolve_tax_rate/3`). A country with no row
  is 0% — threshold-gated markets stay out of the table until they are
  registered (the ADR's watchlist).

  Launch table: EU-27 standard rates + UK, shipped as
  `priv/repo/seeds/tax_rates.yaml` and seeded convergently
  (`FluxVale.Seeds.seed_tax_rates!/0`); rate changes land as YAML
  diffs. The shipped table **must be re-verified against the official
  source before production** — the registrations gate — it is launch
  data, not an audited feed.

  Uniqueness: one rate per jurisdiction per effective date. The
  `(country, state, effective_from)` identity cannot see NULL state
  (Postgres NULL semantics), so a partial unique index on
  `(country, effective_from) WHERE state IS NULL` closes the gap — two
  country-wide rows can never share an effective_from, and the
  resolver's latest-row pick is deterministic.

  Policies mirror `FluxVale.Pricing.Size`: reads for any signed-in
  actor, writes platform-admin (seeds run `authorize?: false`).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Pricing,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "pricing_tax_rates"
    repo FluxVale.Repo

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults id: "nil"

    custom_indexes do
      # The identity's NULL-state gap (see the moduledoc): the
      # country-wide rows need their own unique index.
      index([:country, :effective_from],
        unique: true,
        where: "state IS NULL",
        name: "pricing_tax_rates_country_wide_effective_unique"
      )
    end
  end

  policies do
    policy action_type(:read) do
      description "Any signed-in actor sees the rate table (checkout resolves with an actor upstream)"
      authorize_if(actor_present())
    end

    policy FluxVale.Checks.ActorIsPlatformAdmin do
      description "Platform admins manage rates (ADR-0027, ADR-0030)"
      authorize_if(always())
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    attribute :country, :string do
      allow_nil?(false)
      public?(true)
      constraints(match: ~r/^[A-Z]{2}$/)
    end

    # US state code; nil = country-wide (the shipped table is EU/UK-only).
    attribute :state, :string do
      public?(true)
      constraints(match: ~r/^[A-Z]{2}$/)
    end

    attribute :rate_bp, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 0, max: 10_000)
    end

    attribute :effective_from, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary? true
      accept([:country, :state, :rate_bp, :effective_from])
    end

    update :update do
      primary? true
      # (country, state, effective_from) is the seed's lookup key —
      # immutable after create, like Size's slug.
      accept([:rate_bp])
    end
  end

  code_interface do
    domain FluxVale.Pricing

    define(:create)
    define(:update)
  end

  identities do
    # One rate per jurisdiction per effective date — the seed's
    # idempotency key. The index cannot compare NULL state, so the
    # country-wide gap is closed by the partial unique index in
    # `custom_indexes` (see the moduledoc); state-dated dupes are
    # rejected here.
    identity(:unique_country_state_effective_from, [:country, :state, :effective_from])
  end
end
