defmodule FluxVale.Infrastructure.StorageRequest do
  @moduledoc """
  A member's request for storage above the self-service boundary (#250,
  ADR-0046) — the operator queue's row.

  The member names a **target total** (`requested_gb`, not a delta) with
  a short reason; the action snapshots the org and the current
  allocation, and quotes the target rate through `ResizePreview` (the
  same pricing choice the apply charges, so the shown figure is the
  charged figure by construction). The quote is advisory: approval
  re-prices at the rates in force then (D7).

  The state machine is exactly the issue's four states:
  `requested → approved → applied`, with `rejected` terminal (feedback
  required, shown verbatim to the member) and also the escape hatch for
  an approved request the infrastructure can never apply. Approve is a
  durable decision; the apply is the retryable mechanical step behind
  `Operations.ApplyStorageRequest` — a failed apply leaves the row
  `approved` with `apply_error`, never a lost decision.

  One open request per instance: the partial unique index on
  `instance_id WHERE status IN ('requested', 'approved')` is the
  invariant's teeth (the `backup_runs` one-active-run precedent); the
  create's validation gives the member plain copy first.

  Writes beyond the member's own create are the operations'
  (`ApproveStorageRequest`/`RejectStorageRequest`/`RetryStorageRequest`
  and the shared apply), and the system's `mark_*` actions run
  `authorize?: false` — the operator gate is the request's own approve
  policy.
  """

  use Ash.Resource,
    otp_app: :flux_vale,
    domain: FluxVale.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  alias FluxVale.Infrastructure.StorageRequest.ApprovalGuard
  alias FluxVale.Infrastructure.StorageRequest.PrepareRequest
  alias FluxVale.Infrastructure.StorageRequest.RejectionGuard

  require Ash.Query

  @for_instance_cap 50

  # The member wire surface: advisory quote and decision fields; the
  # operator internals are private attributes (see the json_api note).
  @default_fields [
    :id,
    :instance_id,
    :organization_id,
    :requested_gb,
    :current_storage_gb,
    :reason,
    :status,
    :quoted_monthly_cents,
    :quoted_current_cents,
    :requested_by_user_id,
    :decided_at,
    :rejection_reason,
    :applied_at
  ]

  # #360 (ADR-0019 §1): the member's request verbs. Approval/rejection
  # stay operator-only in the web console — the machine API has no
  # admin scope (ADR-0046 D8), so no route exists for them.
  json_api do
    type("storage_request")

    # The operator's internal failure detail and identity never ride the
    # member surface: both are private attributes (`public? false`), so
    # AshJsonApi excludes them from every response and sparse fieldset
    # by definition — `hide_fields` only accepts public fields.

    routes do
      # instances:write — the request create; instance_id is the path's.
      post(:request,
        route: "/instances/:instance_id/storage-requests",
        default_fields: @default_fields
      )

      # instances:read — the instance's request history.
      index(:for_instance,
        route: "/instances/:instance_id/storage-requests",
        default_fields: @default_fields
      )

      # instances:read — one request.
      get(:get_by_id, route: "/storage-requests/:id", default_fields: @default_fields)
    end
  end

  postgres do
    table("storage_requests")
    repo(FluxVale.Repo)

    # ADR-0032 §3: no DB-side id default — ids are Ash's job (see User).
    migration_defaults(id: "nil")

    references do
      # Teardown's hard delete takes the request along (the BackupRun
      # posture). The org is a denormalized queue/policy hop; org
      # deletion is not a supported flow (the PocketIdCustody stance).
      reference(:instance, on_delete: :delete)
      reference(:organization, on_delete: :restrict)
    end

    # The one-open-request invariant's teeth (ADR-0046 §3): the
    # validation is advisory, the partial unique index is atomic — a
    # racing second submit fails its insert, never duplicating a queue
    # row. The plain status index serves the queue's filter and count.
    custom_indexes do
      index([:status])

      index([:instance_id],
        name: "storage_requests_one_open_per_instance_index",
        unique: true,
        where: "status IN ('requested', 'approved')"
      )
    end
  end

  policies do
    policy action(:request) do
      description("Members request storage for an instance in their org")
      authorize_if(relates_to_actor_via([:instance, :organization, :members]))
    end

    # One read policy, two ways in (Ash composes a policy's
    # authorize_if conditions as OR, the Wallet precedent): members
    # read their org's requests (the filter arm), platform admins read
    # any (the filter-less arm).
    policy action([:read, :for_instance, :get_by_id]) do
      description("Members read their org's storage requests; platform admins read any")
      authorize_if(relates_to_actor_via([:instance, :organization, :members]))
      authorize_if(FluxVale.Checks.ActorIsPlatformAdmin)
    end

    policy [FluxVale.Checks.ActorIsPlatformAdmin, action(:queue)] do
      description("Platform admins read the whole approval queue (the badge and the live list)")
      authorize_if(always())
    end

    # The operator's decision verbs. The system mark_* actions have NO
    # policy arm — the apply operation runs them `authorize?: false`,
    # so an actor reaching them falls to Ash's default deny.
    policy [FluxVale.Checks.ActorIsPlatformAdmin, action([:approve, :reject, :retry_apply])] do
      description("Platform admins decide and retry storage requests")
      authorize_if(always())
    end
  end

  pub_sub do
    module(Phoenix.PubSub)
    name(FluxVale.PubSub)

    # The operator queue's global topic (the sidebar badge subscribes
    # on every admin page) and the instance page's request topic.
    publish(:request, "storage_requests:queue")
    publish(:request, ["instances", :instance_id, "storage-requests"])

    publish(:approve, "storage_requests:queue")
    publish(:approve, ["instances", :instance_id, "storage-requests"])

    publish(:reject, "storage_requests:queue")
    publish(:reject, ["instances", :instance_id, "storage-requests"])

    publish(:mark_applied, "storage_requests:queue")
    publish(:mark_applied, ["instances", :instance_id, "storage-requests"])

    publish(:mark_apply_failed, "storage_requests:queue")
    publish(:mark_apply_failed, ["instances", :instance_id, "storage-requests"])
  end

  attributes do
    uuid_v7_primary_key(:id)

    # The target TOTAL, not a delta (D1) — the instance row, the PVC,
    # and the price all speak totals. The hard max is the bigint-encode
    # safety bound (Instance's stance); the configurable attachable
    # ceiling (`storage_beyond_threshold.max_gb`) is the create's
    # validation.
    attribute :requested_gb, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 1, max: 10_240)
    end

    # Snapshot at request, for the queue and the audit.
    attribute :current_storage_gb, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 0)
    end

    attribute :reason, :string do
      allow_nil?(false)
      public?(true)
      constraints(max_length: 280)
    end

    attribute :status, FluxVale.Infrastructure.Types.StorageRequestStatus do
      allow_nil?(false)
      default(:requested)
      public?(true)
    end

    # Advisory quotes (D7): the target rate and the design-time "from"
    # figure, both through ResizePreview. nil = the version is unpriced
    # (the member copy says the rate is confirmed at approval).
    attribute :quoted_monthly_cents, :integer do
      public?(true)
      constraints(min: 0)
    end

    attribute :quoted_current_cents, :integer do
      public?(true)
      constraints(min: 0)
    end

    # Plain ids, no FK — the request outlives a deleted user (the
    # audit's actor reference, not an ownership edge).
    attribute :requested_by_user_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :decided_by_user_id, :uuid do
      public?(false)
    end

    attribute :decided_at, :utc_datetime_usec do
      public?(true)
    end

    attribute :rejection_reason, :string do
      public?(true)
      constraints(max_length: 500)
    end

    # Operator-only technical detail (private, so off the member wire);
    # nil = clean.
    attribute :apply_error, :string do
      public?(false)
    end

    attribute :applied_at, :utc_datetime_usec do
      public?(true)
    end

    # The decision/apply serialization (#250): EVERY state write locks
    # on this version, so a racing approve/reject/retry/mark refuses the
    # slower one instead of overwriting a newer state with a stale
    # struct (the set_exposure precedent).
    attribute :version, :integer do
      allow_nil?(false)
      default(1)
      public?(false)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :instance, FluxVale.Infrastructure.Instance do
      allow_nil?(false)
      public?(true)
    end

    # Denormalized from the instance at create (never input) — the
    # queue's org hop and the wallet gate's key.
    belongs_to :organization, FluxVale.Accounts.Organization do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :request do
      description(
        "A member's storage request: target above the self-service boundary, quoted, one open per instance."
      )

      primary?(true)
      accept([:requested_gb, :reason])

      # Path-fed like BackupSetting :save — the JSON:API route's
      # `:instance_id` segment feeds the argument by name; the change
      # copies it onto the attribute.
      argument(:instance_id, :uuid, allow_nil?: false, public?: true)

      change(PrepareRequest)
    end

    read :for_instance do
      description("One instance's requests, newest first (the member list and the API route).")
      argument(:instance_id, :uuid, allow_nil?: false)

      filter(expr(instance_id == ^arg(:instance_id)))
      prepare(build(sort: [created_at: :desc, id: :desc]))

      prepare(fn query, _context ->
        Ash.Query.limit(query, @for_instance_cap)
      end)
    end

    read :get_by_id do
      description("One request by id (the API's single read).")
      get?(true)
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :queue do
      description(
        "The operator queue: optional status filter and a reason/id search, newest first, paginated at 100 and countable for the badge."
      )

      argument(:status, FluxVale.Infrastructure.Types.StorageRequestStatus,
        allow_nil?: true,
        public?: true
      )

      argument(:search, :string, allow_nil?: true, public?: true)

      prepare(build(sort: [created_at: :desc, id: :desc]))
      prepare(&filter_queue/2)

      # 100 is the moderation/people list's cap; countable gives the
      # sidebar badge the full pending count inside the page metadata.
      pagination(
        keyset?: true,
        required?: false,
        paginate_by_default?: true,
        default_limit: 100,
        max_page_size: 100,
        countable: :by_default
      )
    end

    update :approve do
      description(
        "The operator's durable decision: requested → approved, guarding the live instance, the stale target, the cluster capability, and the funded wallet. No cluster I/O — the apply follows."
      )

      require_atomic?(false)
      change(optimistic_lock(:version))
      change(ApprovalGuard)
    end

    update :reject do
      description(
        "The operator's terminal rejection with member-visible feedback — from requested, or from approved when the apply can never succeed."
      )

      require_atomic?(false)
      accept([:rejection_reason])
      change(optimistic_lock(:version))
      change(RejectionGuard)
    end

    update :retry_apply do
      description("The operator's retry of an approved request's apply — no decision is written.")

      require_atomic?(false)
      change(optimistic_lock(:version))

      change(fn changeset, _context ->
        if changeset.data.status == :approved do
          changeset
        else
          Ash.Changeset.add_error(
            changeset,
            "only an approved storage request can be retried"
          )
        end
      end)
    end

    # System-only (no policy arm; the apply runs authorize?: false).
    update :mark_applied do
      description("The apply's success mark: approved → applied.")

      require_atomic?(false)
      change(optimistic_lock(:version))

      change(fn changeset, _context ->
        if changeset.data.status == :approved do
          changeset
          |> Ash.Changeset.force_change_attribute(:status, :applied)
          |> Ash.Changeset.force_change_attribute(:applied_at, DateTime.utc_now())
          |> Ash.Changeset.force_change_attribute(:apply_error, nil)
        else
          Ash.Changeset.add_error(
            changeset,
            "only an approved storage request can be marked applied"
          )
        end
      end)
    end

    update :mark_apply_failed do
      description("The apply's failure mark: the request stays approved with the honest error.")

      require_atomic?(false)
      argument(:error, :string, allow_nil?: false)
      change(optimistic_lock(:version))

      change(fn changeset, _context ->
        if changeset.data.status == :approved do
          Ash.Changeset.force_change_attribute(
            changeset,
            :apply_error,
            Ash.Changeset.get_argument(changeset, :error)
          )
        else
          Ash.Changeset.add_error(
            changeset,
            "only an approved storage request can record an apply failure"
          )
        end
      end)
    end
  end

  code_interface do
    domain(FluxVale.Infrastructure)

    define(:request)
    define(:for_instance, args: [:instance_id])
    define(:get_by_id, args: [:id])
    define(:queue)
    define(:approve)
    define(:reject)
    define(:retry_apply)
    define(:mark_applied)
    define(:mark_apply_failed)
  end

  # The queue's runtime filters: an optional status, then a search over
  # the reason text and the two ids. A UUID-shaped term matches the ids
  # exactly; a long id list would be a LIKE on text, so the exact match
  # is the honest shape.
  defp filter_queue(query, _context) do
    query
    |> filter_queue_status()
    |> filter_queue_search()
  end

  defp filter_queue_status(query) do
    case Ash.Query.get_argument(query, :status) do
      nil -> query
      status -> Ash.Query.filter(query, status == ^status)
    end
  end

  defp filter_queue_search(query) do
    case Ash.Query.get_argument(query, :search) do
      # Ash's string cast turns a blank term into nil, so the empty
      # input needs no separate arm.
      nil ->
        query

      search ->
        term = String.downcase(search)

        case Ecto.UUID.cast(search) do
          {:ok, id} ->
            Ash.Query.filter(
              query,
              contains(string_downcase(reason), ^term) or id == ^id or instance_id == ^id
            )

          :error ->
            Ash.Query.filter(query, contains(string_downcase(reason), ^term))
        end
    end
  end
end
