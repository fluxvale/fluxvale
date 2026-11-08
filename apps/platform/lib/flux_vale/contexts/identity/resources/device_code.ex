defmodule FluxVale.Identity.DeviceCode do
  @moduledoc """
  One RFC 8628 device-flow sign-in request (#362 T3, OQ #9's
  pre-decided wire): the `device_code` the CLI polls with, the
  `user_code` its human compares against the approval panel, and the
  state the poll endpoint's answers ride.

  Lifecycle: :pending (minted by `POST /api/v1/device/code`) →
  :approved / :denied (the developer settings page's Device sign-ins
  section) → :consumed (the first poll that finds :approved mints the
  PAT and burns the row's one-time delivery). :expired exists in the
  state machine but nothing ever SETS it — expiry rides the timestamp
  (`expires_at`), which the endpoints compare per request (a stored
  status could only lag the clock); the poll answers `expired_token`
  for any row past `expires_at`.

  Deliberately no JSON:API surface and no AshAdmin (the Identity
  stance). The two endpoints are the callers: unauthenticated plain
  JSON outside the ash_json_api router (RFC 8628 bodies, and the
  device has no token yet — the flow is how it earns one). The
  approval panel is the only actor-facing surface: signed-in users
  read the PENDING rows (unattributed by design — approval binds the
  row to the CLICKING user, so there is no cross-user record to
  protect) and act through :approve / :deny. Everything else is
  default-forbidden system surface (the RequestWindow posture).

  `device_code` is stored readable, sensitive? only (spec shape — the
  unique identity IS the value). The stored value is a live capability
  for at most `ttl_seconds/0`, and only the approval click stands
  between it and a token — the same window and posture as the
  JWT-era wire OQ #9 recorded.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.Identity.DeviceCode.FirstPartyClient
  alias FluxVale.Identity.DeviceCode.RequireStatus

  # Defined before the section that consumes it (Spark resolves DSL
  # option values at expansion time); the mint operation reads it via
  # ttl_seconds/0 and the endpoints echo it as `expires_in`, so the
  # wire and the stamps can't drift apart.
  @ttl_seconds 10 * 60

  postgres do
    table("device_codes")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    # Approval binds the row to the approver — teardown of the account
    # takes its device rows along (the PAT table's own on_delete
    # posture; a deleted user's rows can never answer a poll).
    references do
      reference(:user, on_delete: :delete)
    end
  end

  # The actor-facing slice is the approval panel only (see moduledoc);
  # every other action stays default-forbidden for every actor — the
  # system callers (the endpoints' lookups, the mint, the poll's
  # stamps, the janitor) pass `authorize?: false` with comments in
  # place, the RequestWindow posture.
  #
  # Revisit trigger (the shared-pending-list trade): the panel lists
  # every pending sign-in request to any signed-in user — pending rows
  # are unattributed by construction (the mint endpoint is
  # unauthenticated; there is nobody to scope to), approval binds the
  # row to the clicking actor, and the single first-party client makes
  # the list "CLI sign-ins" rather than user mail. This tightens with
  # the client registry (OQ #9's deferred half): per-code claiming
  # (a session-bound claim when the human enters their code, GitHub's
  # entry step) re-scopes the list per user. Promotes alongside that
  # registry; a measured abuse of the panel is the other trigger.
  policies do
    policy action(:pending) do
      description("The approval panel's list — signed-in users see pending sign-in requests")
      authorize_if(actor_present())
    end

    policy action(:approve) do
      description("A signed-in user approves — the row binds to THEM, the PAT mints for them")
      authorize_if(actor_present())
    end

    policy action(:deny) do
      description("A signed-in user denies a pending sign-in request")
      authorize_if(actor_present())
    end
  end

  attributes do
    # ADR-0032: UUIDv7 — explicit default required (the built-in still
    # generates v4)
    uuid_primary_key(:id, type: :uuid_v7, default: &Ash.UUIDv7.generate/0)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    # The CLI's poll handle: 43 url-safe chars of 256-bit randomness
    # (the PAT random's shape). sensitive? keeps it out of logs and
    # error output; the poll endpoint is its only reader.
    attribute :device_code, :string do
      allow_nil?(false)
      sensitive?(true)
      constraints(max_length: 64)
    end

    # The human-typed code, display shape "XXXX-XXXX" — 8 chars over
    # the no-confusables alphabet (no I/L/O/0/1), so a human never
    # guesses between lookalikes. The panel shows it; the human
    # compares it with their terminal.
    attribute :user_code, :string do
      allow_nil?(false)
      public?(true)
      constraints(max_length: 9)
    end

    # The one seeded first-party client today (FirstPartyClient
    # validates against `config :flux_vale, :device_flow_client_id`).
    attribute :client_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :scopes, {:array, :string} do
      allow_nil?(false)
      default([])
      public?(true)
    end

    attribute :status, :atom do
      allow_nil?(false)
      default(:pending)
      # :expired is never written (see moduledoc) — it exists so the
      # state machine names the wire's fifth answer honestly.
      constraints(one_of: [:pending, :approved, :denied, :expired, :consumed])
    end

    # nil until an approval binds the row to the clicking user — the
    # user the PAT then mints FOR.
    attribute(:user_id, :uuid)

    attribute :expires_at, :utc_datetime do
      allow_nil?(false)
      public?(true)
    end

    # The poll machine's bookkeeping: last_polled_at moves only on
    # polls the server COUNTED (the `slow_down` refusals never stamp —
    # a hammering client stays refused until it actually backs off),
    # poll_count counts those counted polls.
    attribute(:last_polled_at, :utc_datetime)

    attribute :poll_count, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
    end
  end

  relationships do
    belongs_to :user, FluxVale.Identity.User do
      public?(false)
    end
  end

  actions do
    # No defaults — every read/write is named and its posture is
    # visible (the RequestWindow stance).
    defaults([])

    create :create do
      primary?(true)
      accept([:device_code, :user_code, :client_id, :scopes, :expires_at])

      # The catalog guard rejects off-catalog or duplicate scopes at
      # the resource — PersonalAccessToken's second door, shared
      # verbatim: the client registry is the deferred half (OQ #9),
      # the catalog is not.
      validate(FluxVale.Identity.PersonalAccessToken.ScopesCatalog,
        where: changing(:scopes)
      )

      # The client guard: only the seeded first-party client mints
      # rows (see FirstPartyClient — the registry upgrade lands beside
      # it, nothing here changes).
      validate(FirstPartyClient, where: changing(:client_id))
    end

    read :pending do
      description("Pending sign-in requests — the approval panel's list, newest first")
      filter(expr(status == :pending and expires_at > now()))
      prepare(build(sort: [created_at: :desc]))
    end

    read :get_by_device_code do
      description("Resolve a row by its device_code — the poll endpoint's system lookup")
      get?(true)
      argument(:device_code, :string, allow_nil?: false, sensitive?: true)
      filter(expr(device_code == ^arg(:device_code)))
    end

    read :get_by_user_code do
      description("""
      Resolve a pending row by its user_code — the system lookup for
      the §3.3 verification_uri_complete shape (the CLI deep-links it;
      the panel reads the pending list, not this)
      """)

      get?(true)
      argument(:user_code, :string, allow_nil?: false)
      filter(expr(user_code == ^arg(:user_code)))
    end

    update :approve do
      description("""
      The panel's Approve: binds the row to the clicking user (the
      argument the caller passes from the actor — the poll then mints
      the PAT FOR that user)
      """)

      accept([])
      # Non-atomic by trade: no primary read exists for the atomic
      # upgrade path (every read here is named — the RequestWindow
      # stance). The guard below is a filtered UPDATE … WHERE, which
      # stays row-safe without the atomic machinery.
      require_atomic?(false)
      # The bind is the ACTOR — never a caller-supplied id (a
      # caller-supplied id would let any signed-in user point a
      # pending sign-in at someone else's account, and the poll's
      # self-mint would hand them that user's PAT).
      change(set_attribute(:user_id, actor(:id)))
      # Guarded write: only a still-pending row approves — a deny (or
      # a consume that somehow raced first) wins, the loser's filtered
      # write returns StaleRecord (the gateway resume posture).
      change({RequireStatus, status: :pending})
      change(set_attribute(:status, :approved))
    end

    update :deny do
      description("The panel's Deny: the poll answers access_denied forever after")
      accept([])
      require_atomic?(false)
      change({RequireStatus, status: :pending})
      change(set_attribute(:status, :denied))
    end

    update :touch_poll do
      description("Stamp a counted poll — system write from the poll endpoint")
      accept([])
      require_atomic?(false)
      change({RequireStatus, status: :pending})
      change(set_attribute(:last_polled_at, &DateTime.utc_now/0))
      change(atomic_update(:poll_count, expr(poll_count + 1)))
    end

    update :consume do
      description("""
      The poll's exactly-once latch: flips :approved → :consumed, and
      only from :approved — two polls race one winner (the loser sees
      StaleRecord and answers authorization_pending; its next poll
      reads :consumed → expired_token). The token crosses the wire
      once
      """)

      accept([])
      require_atomic?(false)
      change({RequireStatus, status: :approved})
      change(set_attribute(:status, :consumed))
    end

    read :stale do
      description("Rows dead for longer than the retention horizon — the janitor prune feed")

      argument(:cutoff, :utc_datetime, allow_nil?: false)

      # Dead means: past expiry (any status — a timestamp, not a
      # status; see moduledoc), or terminal-consumed/denied long ago.
      # A fresh :consumed/:denied row survives its first day so a poll
      # racing the sweep still answers expired_token, not "unknown".
      filter(
        expr(
          expires_at < ^arg(:cutoff) or
            (status in [:consumed, :denied] and updated_at < ^arg(:cutoff))
        )
      )
    end

    destroy :expunge_stale do
      description("Janitor sweep of stale device codes — system call only")
    end
  end

  code_interface do
    domain(FluxVale.Identity)

    define(:pending)
    define(:get_by_device_code, args: [:device_code])
    define(:get_by_user_code, args: [:user_code])
    define(:approve)
    define(:deny)
    define(:touch_poll)
    define(:consume)
  end

  identities do
    # The poll resolves by device_code, the panel's deep link by
    # user_code — both unique by construction (the mint retries the
    # astronomically rare user_code collision).
    identity(:unique_device_code, [:device_code])
    identity(:unique_user_code, [:user_code])
  end

  @doc """
  The code TTL in seconds — minted rows stamp `expires_at` from it and
  the mint endpoint echoes it as `expires_in` (one tie, AuthCode's
  ttl_minutes/0 posture).
  """
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds
end
