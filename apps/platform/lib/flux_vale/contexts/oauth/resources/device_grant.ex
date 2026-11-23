defmodule FluxVale.OAuth.DeviceGrant do
  @moduledoc """
  One OAuth device-grant request (#886): the `device_code` the CLI
  polls with (stored only as its SHA-256 hash — this one mints an
  OAuth token family, so nothing readable survives the row), the
  `user_code` its human compares on the hosted page, and the state the
  poll's answers ride.

  The remote/headless answer to the loopback callback (#886): nothing
  code-shaped ever crosses a redirect or a localhost URL — the
  approval binds the row to the approving user and the poll mints the
  pair. The mint carries an S256 PKCE challenge; the poll must present
  its verifier, so a stolen `device_code` alone cannot redeem (beyond
  RFC 8628, which has no PKCE — the device_code is the whole proof
  there).

  Lifecycle: :pending (minted by `POST /oauth/device/code`) →
  :approved / :denied (the hosted page's Allow/Deny, #886 S2) →
  :consumed (the first poll that finds :approved mints the pair and
  burns the row's one-time delivery). :expired exists in the state
  machine but nothing ever SETS it — expiry rides the timestamp
  (`expires_at`), which the poll compares per request (a stored status
  could only lag the clock); the poll answers `expired_token` for any
  row past `expires_at`.

  System-only rows (the RequestWindow posture): empty policies, no
  actor surface, the authorization-server operations call
  `authorize?: false`. The hosted page is the only actor-facing
  surface, and it acts through :approve / :deny with the ACTOR as the
  bound user.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.OAuth,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias FluxVale.OAuth.DeviceGrant.RequireStatus

  # The mint operation reads this for the wire's `expires_in` and the
  # row's own expires_at — one constant, so the two cannot drift.
  @ttl_seconds 10 * 60

  # The poll machine's interval (seconds between COUNTED polls) —
  # mint and poll both read it here, so the wire's `interval` and the
  # slow_down gate cannot drift apart.
  @poll_interval_seconds 5

  postgres do
    table("oauth_device_grants")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    references do
      reference(:user, on_delete: :delete)
      reference(:client, on_delete: :delete)
    end
  end

  # Deliberately empty (the AuthorizationCode posture): with the
  # Policy authorizer attached, a policy-less action is forbidden to
  # every actor; the AS operations are system calls (`authorize?:
  # false` with comments in place).
  policies do
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    # Only the SHA-256 hash of the poll handle is stored (the
    # AuthorizationCode posture): the raw device_code crosses the wire
    # once at mint and once at poll, and is never recoverable from the
    # row. 43 url-safe chars of 256-bit randomness hashed to 64 hex.
    attribute :device_code_hash, :string do
      allow_nil?(false)
      public?(false)
      sensitive?(true)
      constraints(max_length: 64)
    end

    # The human-typed code, display shape "XXXX-XXXX" — 8 chars over
    # the no-confusables alphabet (no I/L/O/0/1; the Identity device
    # flow's shape). The hosted page shows it; the human compares it
    # with their terminal.
    attribute :user_code, :string do
      allow_nil?(false)
      public?(false)
      constraints(max_length: 9)
    end

    attribute :scopes, {:array, :string} do
      allow_nil?(false)
      default([])
      public?(false)
    end

    attribute :resource, :string do
      allow_nil?(false)
      public?(false)
      constraints(max_length: 2048)
    end

    # The mint-time S256 challenge — the poll must present its
    # verifier (the issue's security shape: a wrong local process that
    # reads the device_code still cannot redeem without the verifier).
    attribute :code_challenge, :string do
      allow_nil?(false)
      public?(false)
      constraints(max_length: 128)
    end

    attribute :status, :atom do
      allow_nil?(false)
      default(:pending)
      # :expired is never written (see moduledoc) — it exists so the
      # state machine names the wire's fifth answer honestly.
      constraints(one_of: [:pending, :approved, :denied, :expired, :consumed])
    end

    # nil until an approval binds the row to the approving user — the
    # user the poll then mints the pair FOR.
    attribute(:user_id, :uuid)

    attribute :expires_at, :utc_datetime do
      allow_nil?(false)
      public?(false)
    end

    # The poll machine's bookkeeping: last_polled_at moves only on
    # polls the server COUNTED (the slow_down refusals never stamp — a
    # hammering client stays refused until it actually backs off),
    # poll_count counts those counted polls (the Identity device
    # flow's shape).
    attribute(:last_polled_at, :utc_datetime)

    attribute :poll_count, :integer do
      allow_nil?(false)
      default(0)
      public?(false)
      constraints(min: 0)
    end
  end

  relationships do
    belongs_to :client, FluxVale.OAuth.Client do
      allow_nil?(false)
      public?(false)
    end

    belongs_to :user, FluxVale.Identity.User do
      public?(false)
    end
  end

  actions do
    defaults([])

    create :mint do
      description("System write — one device-grant request")

      accept([
        :device_code_hash,
        :user_code,
        :scopes,
        :resource,
        :code_challenge,
        :expires_at,
        :client_id
      ])

      validate(FluxVale.Identity.PersonalAccessToken.ScopesCatalog, where: changing(:scopes))
    end

    read :get_by_device_code_hash do
      description("Resolve a grant by its device_code hash — the poll's system lookup")
      get?(true)
      argument(:device_code_hash, :string, allow_nil?: false, sensitive?: true)
      filter(expr(device_code_hash == ^arg(:device_code_hash)))
    end

    read :get_by_user_code do
      description(
        "Resolve a grant by its user_code — the hosted page's lookup; callers gate on status (the poll reads :consumed, the page renders only :pending)"
      )

      get?(true)
      argument(:user_code, :string, allow_nil?: false)
      filter(expr(user_code == ^arg(:user_code)))
    end

    read :stale do
      description("Rows dead past the retention horizon — the janitor prune feed")

      argument(:cutoff, :utc_datetime, allow_nil?: false)

      # Dead means: past expiry (any status — a timestamp, not a
      # status), or terminal-consumed/denied long ago. A fresh
      # :consumed/:denied row survives its first day so a poll racing
      # the sweep still answers expired_token, not "unknown" (the
      # Identity device flow's shape).
      filter(
        expr(
          expires_at < ^arg(:cutoff) or
            (status in [:consumed, :denied] and updated_at < ^arg(:cutoff))
        )
      )
    end

    update :approve do
      description("""
      The hosted page's Allow: binds the row to the clicking user (the
      actor, never a caller-supplied id) — the poll then mints the
      pair FOR that user
      """)

      accept([])
      # Non-atomic by trade: no primary read exists for the atomic
      # upgrade path (the Identity device flow's stance).
      require_atomic?(false)
      change(set_attribute(:user_id, actor(:id)))
      # Guarded write: only a still-pending row approves — a deny (or
      # a consume that somehow raced first) wins, the loser's filtered
      # write returns StaleRecord.
      change({RequireStatus, status: :pending})
      change(set_attribute(:status, :approved))
    end

    update :deny do
      description("The hosted page's Deny: the poll answers access_denied forever after")
      accept([])
      require_atomic?(false)
      change({RequireStatus, status: :pending})
      change(set_attribute(:status, :denied))
    end

    update :touch_poll do
      description("Stamp a counted poll — system write from the token endpoint")
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
      reads :consumed → expired_token). The pair crosses the wire once
      """)

      accept([])
      require_atomic?(false)
      change({RequireStatus, status: :approved})
      change(set_attribute(:status, :consumed))
    end

    destroy :expunge_stale do
      description("Janitor sweep past the retention horizon — system call only")
    end
  end

  code_interface do
    domain(FluxVale.OAuth)

    define(:get_by_device_code_hash, args: [:device_code_hash])
    define(:get_by_user_code, args: [:user_code])
    define(:approve)
    define(:deny)
    define(:touch_poll)
    define(:consume)
  end

  identities do
    identity(:unique_device_code_hash, [:device_code_hash])
    identity(:unique_user_code, [:user_code])
  end

  @doc """
  The grant's TTL in seconds — the mint response's `expires_in` and
  the row's own `expires_at` read one constant.
  """
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc """
  The seconds between COUNTED polls — the mint response's `interval`
  and the poll's slow_down gate read one constant.
  """
  @spec poll_interval_seconds() :: pos_integer()
  def poll_interval_seconds, do: @poll_interval_seconds
end
