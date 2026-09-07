defmodule FluxVale.Identity.AuthCode do
  @moduledoc """
  Server-owned one-time login codes (ADR-0003): 6-digit, 10-minute TTL,
  single-use, **hashed at rest** (bcrypt — the 20-bit code space makes
  unsalted fast hashes trivially brute-forceable), capped verify attempts.

  Nothing secret ever leaves the server: the sender callback receives the
  plain code only for delivery; the client learns nothing but its mailbox.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # Defined before the section that consumes it (Spark resolves DSL option
  # values at expansion time); Operations reads it via max_attempts/0 so
  # the constraint and the ops pre-check can't drift apart.
  @max_attempts 5

  postgres do
    table "auth_codes"
    repo FluxVale.Repo

    # ADR-0032 §3: no DB-side id default — ids are Ash's job
    migration_defaults id: "nil"

    custom_indexes do
      # Verify lookups: latest unexpired code for an identity
      index [:email, :expires_at]
    end
  end

  # Only the auth flow (interaction bypass) and internal ops touch this
  # table; no human-facing action exists — same posture as Token.
  policies do
    bypass(AshAuthentication.Checks.AshAuthenticationInteraction) do
      description "AshAuthentication can interact with the auth-code store"
      authorize_if(always())
    end
  end

  attributes do
    # ADR-0032: UUIDv7 — explicit default required (the built-in still
    # generates v4)
    uuid_primary_key(:id, type: :uuid_v7, default: &Ash.UUIDv7.generate/0)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    attribute :email, :ci_string do
      allow_nil?(false)
    end

    # bcrypt hash of the 6-digit code — never the code itself
    attribute :code_hash, :string do
      allow_nil?(false)
      sensitive?(true)
    end

    attribute :expires_at, :utc_datetime do
      allow_nil?(false)
    end

    # Wrong-verify counter. The `max` constraint is the race-safe cap:
    # atomic updates validate constraints inside the SQL statement
    # (CASE ... ash_raise_error), so the 6th increment fails at the
    # database, boundary-parallel guesses included (CWE-307) — a plain
    # read-then-check in the operation layer can never guarantee that.
    attribute :attempts, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0, max: @max_attempts)
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([:email, :code_hash, :expires_at])
    end

    update :register_attempt do
      # Atomic increment — two racing wrong guesses both count; the
      # attempts `max` constraint above is what refuses the 6th (CWE-307)
      change(atomic_update(:attempts, expr(attempts + 1)))
    end

    destroy :burn do
      description "Single-use: destroy on successful verify — the arbiter"
      # Optimistic lock: concurrent burns race on attempts; exactly one
      # wins — the 0-row loser gets a stale error and mints nothing (CWE-367)
      change(optimistic_lock(:attempts))
    end

    read :active_for_email do
      description "Unexpired codes for an identity (ops layer picks the latest)"

      argument(:email, :ci_string, allow_nil?: false)

      filter(expr(email == ^arg(:email) and expires_at > now()))
    end
  end

  @doc "The verify-attempt cap (see the atomic guard on register_attempt)"
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts
end
