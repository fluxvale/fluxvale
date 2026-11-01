defmodule FluxVale.Infrastructure.AccessGateway.StateMarkers do
  @moduledoc """
  Emits the gateway state-change counter — the billing switch's
  telemetry: the six mounted state writers (the observer's
  `:update_state`, the ladder's suspend, the owner's resume, the
  key re-paste, the two error handlers) land one event, so the
  dashboard shows ladder suspends distinctly from observed failures
  and error-handler landings. The re-paste's recovery edge
  (`:needs_attention → :provisioning`, force-changed in
  RepasteCredential's before_action) is an EXIT from
  :needs_attention — the occupancy alert reads entries minus exits,
  so that edge counts like any other.

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
  never fail the state write carrying it. That stance has one accepted
  orphan and one suppressed phantom:

  - Accepted orphan: Resume's scale runs in an after_action registered
    AFTER this one, so a failed scale-up emits one
    `:suspended → :provisioning` sample for a write that then rolls
    back. Rare (a resume-time cluster failure), and it never touches
    the needs_attention edges the occupancy math reads.
  - Suppressed phantom: a token-drift claim's nested drift write
    (`ClaimAccessDomain.drift_to_needs_attention/2`, inside the
    access-domain resume's about-to-roll-back transaction) WOULD emit
    a `:needs_attention` entry the rollback cannot retract — the emit
    fires synchronously, before and independent of the commit — and
    the resume's after_transaction fallback would then emit the real
    one, double-counting the entry for a week of occupancy. That
    caller passes `context: %{suppress_state_markers: true}` on its
    nested write; this change skips emission when the flag is set, so
    only the fallback's persisted write counts.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @state_event [:flux_vale, :gateway, :state_change]

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    if changeset.context[:suppress_state_markers] do
      changeset
    else
      emit_on_write(changeset)
    end
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (after_action emission)
  def atomic?, do: false

  # Registered only on unsuppressed writes; the from/to decision stays
  # post-write (see the moduledoc).
  defp emit_on_write(changeset) do
    Changeset.after_action(changeset, fn _changeset, record ->
      emit_if_changed(changeset.data.state, record)
      {:ok, record}
    end)
  end

  defp emit_if_changed(from, record) do
    if record.state != from do
      :telemetry.execute(@state_event, %{count: 1}, %{from: from, to: record.state})
    end
  end
end
