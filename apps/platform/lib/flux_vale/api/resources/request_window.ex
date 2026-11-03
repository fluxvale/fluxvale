defmodule FluxVale.Api.RequestWindow do
  @moduledoc """
  A per-token fixed-window request counter for `/api/v1` (#360 slice
  3, ADR-0019 §4): one row per `{token, window}`, its `count` bumped
  once per PAT-authenticated call — the store behind
  `FluxValeWeb.Plugs.ApiRateLimit`.

  System-only metering rows: no actor-facing surface exists, so the
  policies block stays empty (default forbid — the PAT resource's
  `:touch_last_used` posture, table-wide) and the system calls
  (`authorize?: false`, comments in place) write through
  `FluxVale.Api.Operations.BumpRequestWindow` (raw SQL, the why lives
  there) and the janitor's expunge. No JSON:API routes (not a
  machine-API resource), no AshAdmin (ADR-0027 §3 stance).
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Api,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("request_windows")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    # Metering rows are derivative of the token — teardown of the
    # token (user deletion) takes its windows along (the PAT table's
    # own on_delete posture).
    references do
      reference(:token, on_delete: :delete)
    end
  end

  # Deliberately empty: with the Policy authorizer attached, a
  # policy-less action is forbidden to every actor. Only the system
  # calls (bump from the boundary plug, expunge from the janitor —
  # both `authorize?: false` with comments in place) touch this table.
  policies do
  end

  attributes do
    uuid_v7_primary_key(:id)

    create_timestamp(:created_at)
    update_timestamp(:updated_at)

    # 1, not 0: a row exists only once a request has been counted in
    # its window — the fresh-insert arm of the upsert-increment.
    attribute :count, :integer do
      allow_nil?(false)
      default(1)
      public?(false)
    end

    # Whole-second, window-aligned (floor-bucketed — see the plug):
    # two requests count into the same row iff they floor into the
    # same window.
    attribute :window_started_at, :utc_datetime do
      allow_nil?(false)
      public?(false)
    end
  end

  relationships do
    belongs_to :token, FluxVale.Identity.PersonalAccessToken do
      allow_nil?(false)
      public?(false)
    end
  end

  actions do
    defaults([])

    read :stale do
      description("Windows started before the cutoff — the janitor prune feed")
      argument(:cutoff, :utc_datetime, allow_nil?: false)
      filter(expr(window_started_at < ^arg(:cutoff)))
    end

    destroy :expunge_stale do
      description("Janitor sweep of stale windows — system call only")
    end
  end

  identities do
    identity(:unique_token_window, [:token_id, :window_started_at])
  end
end
