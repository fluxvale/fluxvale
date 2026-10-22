defmodule FluxVale.Infrastructure.Instance.MaintainAnchors do
  @moduledoc """
  Maintains the Instance's metering anchors on status transitions
  (ADR-0005 Am. 1, ADR-0028 §2):

  - Entering `:running`: `running_since` = now (start of a billable
    running interval); `storage_metering_since` = now **only if nil** —
    seeded the first time the instance runs, then left alone so storage
    billing spans stop/start (the PVC persists and keeps accruing; a PVC
    on an instance that never went ready accrues nothing — v1 semantics,
    kept per #121). The unbilled carry is untouched: whatever a previous
    stop closed stays pending for the next settle.
  - Leaving `:running` (→ stopped | error | deleting): the interval's
    unbilled time — from the later of `running_since` and the storage
    cursor (the last committed settle) to now — folds into
    `unbilled_running_usec` (accumulating any already-pending time), and
    `running_since` clears. Duration, not timestamps: stop/start churn
    inside one settle tick can never drop or lose an interval.
  - Entering `:lost` (#196): every anchor parks — `running_since` nil,
    `unbilled_running_usec` 0, `storage_metering_since` nil,
    `lost_detected_at` now. The namespace (and its PVC) is gone, so
    nothing accrues from detection on: the settle trigger keys on the
    storage anchor, and `settle_fresh` skips nil-anchor rows. The
    un-drained remainder (≤ one settle tick of running time plus
    detection latency) is deliberately forgiven — the incident's sin
    was billing for nothing, and a few micro-cents of undercharge is
    the safe direction. Re-deploy re-seeds a fresh epoch on the next
    `:running` (the enter-:running branch seeds the nil anchor).

  Transitions never post to the ledger; `settle_usage` is the only
  consumer of the anchors.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

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

      new_status == :lost and old_status != :lost ->
        enter_lost(changeset)

      new_status == :running and old_status != :running ->
        enter_running(changeset)

      old_status == :running and new_status != :running ->
        leave_running(changeset)

      true ->
        changeset
    end
  end

  # Start a fresh running interval; seed the storage anchor on the
  # instance's first-ever deploy. The unbilled carry from an earlier
  # stop stays — settle consumes it.
  defp enter_running(changeset) do
    now = DateTime.utc_now()
    changeset = Changeset.change_attribute(changeset, :running_since, now)

    if is_nil(changeset.data.storage_metering_since),
      do: Changeset.change_attribute(changeset, :storage_metering_since, now),
      else: changeset
  end

  # #196's drain-on-lost guard: parking the storage anchor is what
  # stops metering (the settle trigger and settle_fresh both key on it),
  # atomically with the status write — no window where a dead row keeps
  # accruing. lost_detected_at is the billing-stop audit moment.
  defp enter_lost(changeset) do
    now = DateTime.utc_now()

    changeset
    |> Changeset.change_attribute(:running_since, nil)
    |> Changeset.change_attribute(:unbilled_running_usec, 0)
    |> Changeset.change_attribute(:storage_metering_since, nil)
    |> Changeset.change_attribute(:lost_detected_at, now)
  end

  # Running billing stops at the transition; the interval's unbilled
  # time folds into the carry (the storage cursor bounds it below —
  # everything before the last committed settle is already billed);
  # storage accrual continues on the persisted anchor.
  defp leave_running(changeset) do
    now = DateTime.utc_now()
    data = changeset.data

    pending = data.unbilled_running_usec + unbilled_since(data, now)

    changeset
    |> Changeset.change_attribute(:running_since, nil)
    |> Changeset.change_attribute(:unbilled_running_usec, pending)
  end

  defp unbilled_since(data, now) do
    # Defensive-nil guards: leaving :running implies running_since was
    # set (enter_running owns it) — cover the corrupt-row shape anyway.
    started = data.running_since || now
    bounded = max_datetime(started, data.storage_metering_since || started)

    max(DateTime.diff(now, bounded, :microsecond), 0)
  end

  defp max_datetime(a, b) do
    if DateTime.compare(a, b) == :gt, do: a, else: b
  end
end
