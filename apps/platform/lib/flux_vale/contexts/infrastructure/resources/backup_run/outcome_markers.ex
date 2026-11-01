defmodule FluxVale.Infrastructure.BackupRun.OutcomeMarkers do
  @moduledoc """
  Emits the backup/restore outcome counter + duration on terminal
  finalizes. Mounted on the ONE action both finalize writers share —
  the run operation's apply-failure arm and the sweep's watch pass
  both write through `:update` — so every outcome lands here without
  either operation knowing about metrics.

  `[:flux_vale, :backup, :run]`, measurements `%{count: 1, duration:
  seconds}`, labels `%{kind, status}` — closed enums only. Terminal
  transitions only (`:succeeded`/`:failed` with the row not already
  there): the `:running` flip is progress, not an outcome, and a
  re-finalize over a settled row is not a second backup. That guard
  dedups the sequential shape only — a stale-read race (two
  finalizers holding pre-terminal records; `:update` carries no lock)
  can still double-count one physical run. Accepted: rare by
  construction (the sweep's watch pass owns the row), and the alert's
  volume floor absorbs a single dupe.

  Duration is `finished_at - started_at` in float seconds — 0.0
  defensively when either stamp is missing (a terminal finalize
  without `finished_at` is legal if unsightly; `started_at` is
  allow_nil? false).

  Emission is one synchronous local `:telemetry.execute/3` in
  after_action (post-write, still inside the transaction — the
  WakeMarkers stance): a no-op with no handler attached, so it can
  never fail the finalize write carrying it.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @run_event [:flux_vale, :backup, :run]
  @terminal [:succeeded, :failed]

  @doc """
  The terminal statuses (this module emits on these only) — read by
  FluxVale.PromEx.Plugins.Business to derive the backup pairs. One
  writer: the emitter owns terminality.
  """
  @spec terminal_statuses() :: [atom()]
  def terminal_statuses, do: @terminal

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    old_status = changeset.data.status
    new_status = Changeset.get_attribute(changeset, :status)

    if new_status in @terminal and new_status != old_status do
      Changeset.after_action(changeset, fn _changeset, record ->
        :telemetry.execute(
          @run_event,
          %{count: 1, duration: duration(record)},
          %{kind: record.kind, status: record.status}
        )

        {:ok, record}
      end)
    else
      changeset
    end
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (after_action emission)
  def atomic?, do: false

  defp duration(record) do
    case {record.started_at, record.finished_at} do
      # coveralls-ignore-start - started_at is allow_nil? false; this
      # half of the guard is defensive (only finished_at can be nil).
      {nil, _finished} ->
        0.0

      # coveralls-ignore-stop

      {_started, nil} ->
        0.0

      {started, finished} ->
        DateTime.diff(finished, started, :millisecond) / 1000
    end
  end
end
