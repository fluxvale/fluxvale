defmodule FluxVale.Infrastructure.Instance.StatusMarkers do
  @moduledoc """
  Emits the lifecycle-outcome counter on real status transitions — the
  business-telemetry twin of the PubSub publish: the funnel
  (`:update_status` — the deploy job's and the reconciler's writes,
  sleep/stop/restore, lost) AND the three direct writers outside it
  (the `:deploy` action's own `:deploying` flip, the two Oban error
  handlers' `:error` landings) each emit here, so the dashboard's
  transition rates and the fleet's error-occupancy alert read one
  seam. The direct trio is mounted because the occupancy alert
  consumes exactly those edges: a crashed deploy job (what
  `mark_deploy_error` exists for) is the ENTRY the alert must page on,
  and the owner's error → re-deploy is the EXIT it must release on.

  `[:flux_vale, :instance, :status_transition]`, measurements
  `%{count: 1}`, labels `%{from, to, reason}` — closed enums only
  (cardinality is bounded by the state machine and its failure
  vocabulary, never by fleet size). `reason` is the deploy-failure
  triage lens: set on `:error` writes (read from the record the action
  produced — InstanceK8s enforces the nil pairing elsewhere), nil on
  every other transition. A same-status write (the funnel's legal
  message-only no-op) is not a transition and emits nothing.

  Named acceptance — the `from` label carries the writer's snapshot:
  the unfiltered writers (`InstanceK8s.update_status` writes blind;
  only the gateway observer/resume carry expected-state filters) never
  re-read the row, so a row that moved between the writer's read and
  its write can misattribute one exit. The windows are narrow (the
  reconciler queue is concurrency-1) and the 7d occupancy window
  amplifies only rare cases. Accepted — serving metrics with write
  semantics would invert the WakeMarkers stance (the metric must never
  change the write); revisit if the alert ever pages on a shape the
  dashboard disputes. The fleet alert design carries the same note.

  Emission is one synchronous local `:telemetry.execute/3` in
  after_action (post-write, still inside the transaction — the
  WakeMarkers stance): a no-op with no handler attached, so it can
  never fail the status write carrying it. The `:deploy` and
  error-handler mounts read the status at change time, AFTER their
  force-change changes run — the force-changes are change-time writes,
  not before_action hooks, so the read sees the new status (pinned by
  tests).

  The same change maintains `errored_at` (#182) — stamped on the :error
  entry, cleared on the :error exit, force-changed onto this very
  changeset so the gauge's recency clock and the counter's emission are
  one write (see stamp_errored_at/3).
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @status_event [:flux_vale, :instance, :status_transition]

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

      new_status == old_status ->
        changeset

      true ->
        changeset
        |> stamp_errored_at(old_status, new_status)
        |> Changeset.after_action(fn _changeset, record ->
          :telemetry.execute(@status_event, %{count: 1}, %{
            from: old_status,
            to: new_status,
            reason: record.failure_reason
          })

          {:ok, record}
        end)
    end
  end

  # The stuck-in-error gauge's clock (#182): stamped on the write that
  # lands :error, cleared on the write that leaves it — the same
  # changeset that emits the transition counter, so the gauge and the
  # counter can never disagree about when an error began. Same-status
  # writes (the reconcile no-ops that bump updated_at) never touch it:
  # the stamp is the episode's true entry instant, once per episode.
  defp stamp_errored_at(changeset, _old_status, :error) do
    Changeset.force_change_attribute(changeset, :errored_at, DateTime.utc_now())
  end

  defp stamp_errored_at(changeset, :error, _new_status) do
    Changeset.force_change_attribute(changeset, :errored_at, nil)
  end

  defp stamp_errored_at(changeset, _old_status, _new_status), do: changeset

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (after_action emission)
  def atomic?, do: false
end
