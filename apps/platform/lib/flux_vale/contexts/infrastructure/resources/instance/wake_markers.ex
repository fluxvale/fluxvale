defmodule FluxVale.Infrastructure.Instance.WakeMarkers do
  @moduledoc """
  Maintains the wake-latency markers on status transitions (#232) —
  the instrumentation twin of MaintainAnchors: billing anchors there,
  wake clocks here.

  - The `start` action stamps `wake_requested_at` when waking from
    `:sleeping` — the request instant nothing else records (the edge
    marker knows it; until #232 the row didn't).
  - Entering `:starting` with a request stamped: `wake_promoted_at` =
    now — stamped in the same status write that lands `:starting`
    (immediately after the Deployment scale ack) — and
    `[:flux_vale, :wake, :promotion]` fires post-commit: requested →
    promoted, the PLATFORM's part of the wake.
  - Entering `:running` with both stamped: both clear, and
    `[:flux_vale, :wake, :boot]` (promoted → running) plus
    `[:flux_vale, :wake, :total]` (requested → running) fire. Boot
    deliberately includes reconcile-cadence latency — the visitor
    sees `:running` only after the minute cron flips it, so the SLI
    measures the platform's whole wake path, poll granularity
    included; improvement pressure lands on cadence too.
  - Entering `:error`/`:lost`/`:sleeping` clears both: a wake that
    dies mid-flight never emits a completion, and a stale marker
    can't mis-clock the next cycle (the next wake stamps fresh).

  A plain `start` from `:stopped` is not a wake — no marker, no
  events: the owner's cold start is not the SLI's subject. Fresh
  deploys ride `:deploying`, where the deploy action force-clears the
  markers alongside `lost_detected_at`.

  Events carry `app` — the catalog App's slug — as their ONLY label:
  cardinality is a hard constraint (the Grafana free-tier series
  budget), and per-app is the honest lens — a Kavita wake and a
  Forgejo wake differ by an order of magnitude, so an averaged total
  would be a meaningless number. Emission is one synchronous local
  `:telemetry.execute/3` — a no-op with no handler attached, atomics
  with Peep — and can never block or fail the status write it rides.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @wake_events [:flux_vale, :wake]

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    old_status = changeset.data.status
    new_status = Changeset.get_attribute(changeset, :status)

    cond do
      # coveralls-ignore-start - defensive: unreachable; status is
      # allow_nil? false, so new_status is never nil in practice.
      is_nil(new_status) ->
        changeset

      # coveralls-ignore-stop

      new_status == :starting and old_status != :starting ->
        enter_starting(changeset)

      new_status == :running and old_status != :running ->
        enter_running(changeset)

      true ->
        clear_markers(changeset)
    end
  end

  # The promotion clock stops where StartInstance's scale ack was —
  # this write. Only a marked wake stamps and emits; deploy paths land
  # :starting markerless (the deploy action cleared them on
  # :deploying) and pass through untouched.
  defp enter_starting(changeset) do
    requested = changeset.data.wake_requested_at

    if is_nil(requested) do
      changeset
    else
      promoted = DateTime.utc_now()

      changeset
      |> Changeset.force_change_attribute(:wake_promoted_at, promoted)
      |> Changeset.after_action(fn _changeset, record ->
        emit(:promotion, record, duration(requested, promoted))
        {:ok, record}
      end)
    end
  end

  # The wake completes where the reconciler confirms readiness. Durations
  # read the pre-write markers (changeset.data — the change clears
  # them); emission happens post-commit so a failed write never
  # counts a wake that didn't land.
  defp enter_running(changeset) do
    requested = changeset.data.wake_requested_at
    promoted = changeset.data.wake_promoted_at

    if is_nil(requested) or is_nil(promoted) do
      changeset
    else
      now = DateTime.utc_now()

      changeset
      |> Changeset.force_change_attribute(:wake_requested_at, nil)
      |> Changeset.force_change_attribute(:wake_promoted_at, nil)
      |> Changeset.after_action(fn _changeset, record ->
        emit(:boot, record, duration(promoted, now))
        emit(:total, record, duration(requested, now))
        {:ok, record}
      end)
    end
  end

  # Anything a wake can't complete through clears its clocks — the
  # no-op guard keeps markerless writes (the overwhelmingly common
  # shape) from dirtying every transition.
  defp clear_markers(changeset) do
    if is_nil(changeset.data.wake_requested_at) do
      changeset
    else
      changeset
      |> Changeset.force_change_attribute(:wake_requested_at, nil)
      |> Changeset.force_change_attribute(:wake_promoted_at, nil)
    end
  end

  defp emit(event, instance, seconds) do
    app_slug = app_slug!(instance)

    :telemetry.execute(@wake_events ++ [event], %{duration: seconds}, %{app: app_slug})
  end

  # The `app` label's value — the catalog slug, resolved fresh per
  # emission (wakes are minutes-apart events; two joined reads each
  # is nothing next to denormalizing a mutable name onto every row).
  defp app_slug!(instance) do
    loaded = Ash.load!(instance, [app_version: :app], authorize?: false)
    loaded.app_version.app.slug
  end

  # Float seconds for the histograms. Clamped at zero: an NTP step
  # between clocks can invert a diff, and a negative latency sample
  # is noise, not signal.
  defp duration(from, to) do
    max(DateTime.diff(to, from, :millisecond) / 1000, 0.0)
  end
end
