defmodule FluxValeWeb.AdminHealth do
  @moduledoc """
  The Health section's widget data (#702, ADR-0050 — the operational
  console): one public function per widget, each taking the admin
  actor where Ash is involved. `fleet/1` is the instance fleet
  snapshot: build stamp (env chip + version), the status spread with
  totals, and the newest deploy trail. `wake/0` is the wake widget:
  per-app p95 promotion-wait and median total wake seconds off
  WakeStats' in-memory scrape — no actor, the numbers ride the metrics
  exposition, not Ash.

  The fleet's admissions are distinct: the instance rows ride the
  platform-admin blanket bypass (ActorIsPlatformAdmin outside the
  machine API, #644), while the trail's version rows ride the
  VersionMixin's direct admin-only read policy (ADR-0048 D7). The
  deploy trail reads the Instance Version module through `AdminAudit`'s
  registry — the same string-keyed fetch the audit section's URL
  segments resolve through — and filters `version_action_name ==
  :deploy` — the same newest-first grammar the audit section sorts by.

  `storage/1` is the storage posture: the fleet's allocated gigabytes
  plus the storage-request queue's three counters (ADR-0046's requested
  → approved → applied arc, the badge's own numbers). `runway/1` is the
  org runway: every wallet projected through the billing domain's
  `compute_runway`, low = float runway below the configurable gate
  (one week by default) — the org names ride the flagged
  `Organization :admin_lookup` seam (#501) exactly as the wallets
  surface's do.
  """

  alias FluxVale.Infrastructure.StorageRequest
  alias FluxVale.Observability.WakeStats
  alias FluxValeWeb.AdminAudit
  alias FluxValeWeb.AdminResource

  # The filter expressions parse through Ash.Expr — the require is
  # load-bearing (the audit section's same note).
  require Ash.Query

  @fleet_deploy_limit 5

  # The #501 :admin_lookup action's 200-id constraint — the seam
  # batches its org-name asks under it.
  @lookup_batch 200

  @doc """
  The instance fleet snapshot: every instance read with the admin
  actor, the deploy trail capped at the five newest deploy-action
  version rows. The trail's rows map to the widget's display shape —
  the engine's short id, the recorded actor tombstone, the version's
  own stamp.
  """
  @spec fleet(FluxVale.Identity.User.t()) :: %{
          env: String.t() | nil,
          version: String.t(),
          statuses: %{optional(atom()) => non_neg_integer()},
          total: non_neg_integer(),
          always_on: non_neg_integer(),
          recent_deploys: [
            %{source: String.t(), actor: String.t() | nil, at: DateTime.t()}
          ]
        }
  def fleet(actor) do
    instances = read_instances(actor)

    %{
      env: Application.get_env(:flux_vale, :platform_env),
      version: FluxVale.Build.version(),
      statuses: Enum.frequencies_by(instances, & &1.status),
      total: length(instances),
      always_on: Enum.count(instances, & &1.always_on),
      recent_deploys: recent_deploys(actor)
    }
  end

  defp read_instances(actor) do
    FluxVale.Infrastructure.Instance
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.select([:status, :always_on])
    |> Ash.read!()
  end

  @doc """
  The wake widget's data (#702): per-app p95 promotion-wait and
  median total wake seconds, both through WakeStats' safety wrappers —
  a derived widget can never take the console down. The pair comes
  from one `WakeStats.snapshot/0` read, so both maps quote the same
  computation.
  """
  @spec wake() :: %{
          p95_promotion: %{optional(String.t()) => float()},
          median_total: %{optional(String.t()) => float()}
        }
  def wake do
    snapshot = WakeStats.snapshot()
    %{p95_promotion: snapshot.p95_promotions, median_total: snapshot.medians}
  rescue
    # coveralls-ignore-start - the catalog badges' same wrapper
    # grammar: the widget answers empty rather than take the console
    # down; the named server is alive under the app tree for the whole
    # suite (a call exits only in the supervisor's restart gap, which
    # no test can hold open).
    _exception ->
      %{p95_promotion: %{}, median_total: %{}}
  catch
    :exit, _reason ->
      %{p95_promotion: %{}, median_total: %{}}
      # coveralls-ignore-stop
  end

  @doc """
  The storage posture widget (#702): the fleet's allocated gigabytes —
  the sum over the instance read, `|| 0` because a legacy row without
  an allocation reads as allocated nothing, never as a crash — and the
  operator queue's three state counters, each the queue read's full
  count (the sidebar badge's same number).
  """
  @spec storage(FluxVale.Identity.User.t()) :: %{
          allocated_gb: non_neg_integer(),
          requested: non_neg_integer(),
          approved: non_neg_integer(),
          applied: non_neg_integer()
        }
  def storage(actor) do
    %{
      allocated_gb: allocated_gb(actor),
      requested: storage_queue_count(:requested, actor),
      approved: storage_queue_count(:approved, actor),
      applied: storage_queue_count(:applied, actor)
    }
  end

  @doc """
  The org runway widget (#702): every wallet projected through the
  billing domain's `compute_runway` (balance ÷ burn). Low = a float
  runway below the configured gate (`:low_runway_hours`, one week by
  default); `:infinity` — a wallet with nothing burning — never reads
  low. A projection that errors counts as unknown and renders as such:
  the widget never hides a wallet it could not read.
  """
  @spec runway(FluxVale.Identity.User.t()) :: %{
          threshold_hours: pos_integer(),
          low: [%{org: String.t() | nil, hours: float()}],
          unknown: non_neg_integer(),
          wallets: non_neg_integer()
        }
  def runway(actor) do
    threshold_hours = Application.get_env(:flux_vale, :low_runway_hours, 168)
    wallets = read_wallets(actor)
    org_names = org_names(actor, wallets)

    # The projection reads each org's instances itself (the operation's
    # own contract) — fine at beta scale; the revisit trigger is this
    # line showing up in the console's query budget, at which point a
    # cache (or an org-batched burn read) lands.
    {low, unknown} =
      Enum.reduce(wallets, {[], 0}, fn wallet, {low_acc, unknown_acc} ->
        case FluxVale.Billing.compute_runway(wallet) do
          {:ok, %{runway_hours: :infinity}} ->
            {low_acc, unknown_acc}

          {:ok, %{runway_hours: hours}} when hours < threshold_hours ->
            {[low_row(org_names, wallet, hours) | low_acc], unknown_acc}

          {:ok, _projection} ->
            {low_acc, unknown_acc}

          {:error, _reason} ->
            {low_acc, unknown_acc + 1}
        end
      end)

    %{
      threshold_hours: threshold_hours,
      low: Enum.reverse(low),
      unknown: unknown,
      wallets: length(wallets)
    }
  end

  defp recent_deploys(actor) do
    version_module = instance_version_module()

    version_module
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(version_action_name == :deploy)
    |> Ash.Query.sort(version_inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(@fleet_deploy_limit)
    |> Ash.read!()
    |> Enum.map(fn version ->
      %{
        source: AdminResource.short_uuid(version.version_source_id),
        actor: version.actor_label,
        at: version.version_inserted_at
      }
    end)
  end

  # The Instance entry's Version module, resolved the audit section's
  # way: the registry's string-keyed fetch, never a spelled module
  # match. The registry keeping the :instance entry is the doctrine
  # gate's parity invariant (the admin_authority_test pins the
  # business set AdminAudit mirrors), so :error is unreachable while
  # that gate holds — the raise is the honest loud failure if it ever
  # stops holding.
  defp instance_version_module do
    case AdminAudit.fetch("instance") do
      {:ok, entry} ->
        AdminAudit.version_module(entry)

      :error ->
        # coveralls-ignore-start - unreachable while the doctrine gate's
        # parity test holds: it pins the :instance entry into
        # AdminAudit's set (the invariant test in admin_health_test
        # asserts it directly).
        raise ArgumentError,
              "the AdminAudit registry has no :instance entry — " <>
                "the doctrine gate's parity test must keep the business set intact"

        # coveralls-ignore-stop
    end
  end

  # The fleet read's same shape, narrowed to the one column the sum
  # needs — still a full-table read, not an aggregate. The revisit
  # trigger is fleet size: when the wide read starts to matter, switch
  # to a sum aggregate and this becomes a single scalar read.
  defp allocated_gb(actor) do
    instances =
      FluxVale.Infrastructure.Instance
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.select(:storage_gb)
      |> Ash.read!()

    totals = Enum.map(instances, &(&1.storage_gb || 0))
    Enum.sum(totals)
  end

  # The queue read paginates (countable by default), so the code
  # interface returns a page whose `count` is the full filtered total.
  # The error arm re-raises the Ash error — a member actor is refused
  # by the queue's admin-only policy, and the seam must raise the
  # Forbidden, not pattern-match-crash on it (fleet's grammar).
  defp storage_queue_count(status, actor) do
    case StorageRequest.queue(%{status: status}, actor: actor) do
      {:ok, page} ->
        page.count

      {:error, error} ->
        raise error
    end
  end

  # The billing section's own wallet read (billing.ex refresh_rows):
  # the #644 blanket bypass admits the platform admin, and no balance
  # load — the projection reads its own ledger.
  defp read_wallets(actor) do
    FluxVale.Billing.Wallet
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.read!()
  end

  # The names ride the flagged `:admin_lookup` seam (#501) — the
  # wallets surface's own resolution (billing.ex org_lookup), the one
  # admin-readable org path in every caller posture (the org read
  # policy is members-only, so a relationship load answers only to the
  # blanket bypass and lands refused-or-nil for a PAT caller). The
  # bang form raises the Forbidden itself so the seam keeps the
  # fleet's admin-only grammar; billing.ex matches instead only
  # because its route gate runs first. The read is unbounded (every
  # wallet), so the asks batch under the #501 action's 200-id
  # constraint — a partition past the cap is a 500, not a name.
  defp org_names(actor, wallets) do
    organization_ids = Enum.map(wallets, & &1.organization_id)

    orgs =
      organization_ids
      |> Enum.uniq()
      |> Enum.chunk_every(@lookup_batch)
      |> Enum.flat_map(&org_lookup!(actor, &1))

    Map.new(orgs, fn org -> {org.id, org.name} end)
  end

  defp org_lookup!(actor, ids) do
    FluxVale.Accounts.Organization
    |> Ash.ActionInput.for_action(:admin_lookup, %{ids: ids}, actor: actor)
    |> Ash.run_action!()
  end

  # A vanished org's row renders without a name — impossible while the
  # wallet FK stands (the wallets surface's same stance); nil renders
  # as the honest blank, never a crash.
  defp low_row(org_names, wallet, hours) do
    %{org: Map.get(org_names, wallet.organization_id), hours: hours}
  end
end
