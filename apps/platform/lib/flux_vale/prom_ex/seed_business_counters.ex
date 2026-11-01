defmodule FluxVale.PromEx.SeedBusinessCounters do
  @moduledoc """
  Materializes the business families' 68 closed-enum series at 0,
  once per boot — a sibling child right after the PromEx tree in the
  application supervisor (children start in order, so the handlers
  are attached; FluxVale.Observability gates both on the same env).

  Why: increase() never counts a series' first increment — the fleet
  occupancy rules' contract. The emitters materialize a series only
  on its first event, and these counters are in-memory (every deploy
  resets them), so each edge's first event per process lifetime —
  in practice, the first after every deploy — would otherwise be
  invisible to the alert math. Plugins.Business owns the pair
  derivations (one writer each: the validator table, the state
  enums, the terminality guard).

  LiveDashboard is untouched by the seed: its telemetry listeners
  attach per mounted metrics page, not at boot, so the zero-samples
  never reach it (and its counter definitions count events rather
  than accumulate measurements anyway).

  Boot safety is structural, not defensive: :telemetry detaches a
  failing handler itself (the exception never propagates to the
  emitter — pinned by test), and the task is :temporary, so even a
  crash could not restart-loop or take the supervisor down.
  """

  use Task, restart: :temporary

  alias FluxVale.PromEx.Plugins.Business

  @gateway_event [:flux_vale, :gateway, :state_change]
  @instance_event [:flux_vale, :instance, :status_transition]
  @run_event [:flux_vale, :backup, :run]

  @spec start_link(term()) :: {:ok, pid()}
  def start_link(_arg) do
    Task.start_link(__MODULE__, :run, [])
  end

  @doc """
  Emits the 68 zero-samples — the emitters' own measurement/metadata
  shapes with `count: 0` (the sum metrics accumulate it, so each
  series exists at 0 and stays there). Public so tests run it
  synchronously against a started tree.
  """
  @spec run() :: :ok
  def run do
    Enum.each(Business.instance_transition_pairs(), fn {from, to} ->
      # reason: nil mirrors StatusMarkers' non-error shape — the
      # fleet tags drop it; the dashboard's reason lens reads it.
      seed(@instance_event, %{count: 0}, %{from: from, to: to, reason: nil})
    end)

    Enum.each(Business.gateway_state_pairs(), fn {from, to} ->
      seed(@gateway_event, %{count: 0}, %{from: from, to: to})
    end)

    Enum.each(Business.backup_outcome_pairs(), fn {kind, status} ->
      seed(@run_event, %{count: 0, duration: 0.0}, %{kind: kind, status: status})
    end)

    :ok
  end

  defp seed(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  end
end
