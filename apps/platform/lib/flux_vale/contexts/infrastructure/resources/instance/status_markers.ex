defmodule FluxVale.Infrastructure.Instance.StatusMarkers do
  @moduledoc """
  Emits the lifecycle-outcome counter on real status transitions — the
  business-telemetry twin of the PubSub publish on the same funnel:
  every lifecycle outcome that rides `:update_status` (the deploy
  job's and the reconciler's writes, sleep/stop/restore, lost) lands
  one event here, so the dashboard's transition rates and the fleet's
  error-occupancy alert read ONE funnel instead of per-arm emissions.

  Boundary, named: the pub_sub block's out-of-funnel trio stays
  unemitted — the `:deploy` action's own `:deploying` flip and the two
  Oban error handlers' `:error` writes (a crashed job's landing). If
  an error-occupancy alert needs those crash edges, extend the mounts
  there.

  `[:flux_vale, :instance, :status_transition]`, measurements
  `%{count: 1}`, labels `%{from, to, reason}` — closed enums only
  (cardinality is bounded by the state machine and its failure
  vocabulary, never by fleet size). `reason` is the deploy-failure
  triage lens: set on `:error` writes (read from the record the action
  produced — InstanceK8s enforces the nil pairing elsewhere), nil on
  every other transition. A same-status write (the funnel's legal
  message-only no-op) is not a transition and emits nothing.

  Emission is one synchronous local `:telemetry.execute/3` in
  after_action (post-write, still inside the transaction — the
  WakeMarkers stance): a no-op with no handler attached, so it can
  never fail the status write carrying it.
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
        Changeset.after_action(changeset, fn _changeset, record ->
          :telemetry.execute(@status_event, %{count: 1}, %{
            from: old_status,
            to: new_status,
            reason: record.failure_reason
          })

          {:ok, record}
        end)
    end
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (after_action emission)
  def atomic?, do: false
end
