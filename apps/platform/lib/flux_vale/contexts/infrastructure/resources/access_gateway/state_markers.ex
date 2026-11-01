defmodule FluxVale.Infrastructure.AccessGateway.StateMarkers do
  @moduledoc """
  Emits the gateway state-change counter — the billing switch's
  telemetry: all five state writers (the observer's `:update_state`,
  the ladder's suspend, the owner's resume, the two error handlers)
  land one event, so the dashboard shows ladder suspends distinctly
  from observed failures and error-handler landings.

  `[:flux_vale, :gateway, :state_change]`, measurements `%{count: 1}`,
  labels `%{from, to}` — the closed AccessGatewayState enum only.

  from/to are decided AFTER the write (the pre-write row vs the record
  the action produced), not at change time: Suspend/Resume land their
  state in before_action hooks that run after this change has, so an
  early `get_attribute` read would miss exactly those arms. The
  consequences are the wanted ones — an idempotent arm (Suspend's
  no-op on `:suspended`/`:destroying`, the observer's already-`:active`
  write) lands from == to and emits nothing, and a filter-refused
  write (the observer's StaleRecord) never reaches after_action, so
  its re-read retry emits at most once.

  Emission is one synchronous local `:telemetry.execute/3` in
  after_action (post-write, still inside the transaction — the
  WakeMarkers stance): a no-op with no handler attached, so it can
  never fail the state write carrying it.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @state_event [:flux_vale, :gateway, :state_change]

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Changeset.after_action(changeset, fn _changeset, record ->
      from = changeset.data.state

      if record.state != from do
        :telemetry.execute(@state_event, %{count: 1}, %{from: from, to: record.state})
      end

      {:ok, record}
    end)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (after_action emission)
  def atomic?, do: false
end
