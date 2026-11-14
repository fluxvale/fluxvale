defmodule FluxVale.Infrastructure.Instance.StatusTransition do
  @moduledoc """
  Validation for Instance status transitions (ADR-0005 state machine).

  Enforces valid transitions:

  - pending → deploying, error
  - deploying → starting, error
  - starting → running, no_capacity, error, lost
  - running → stopped, sleeping, restoring, no_capacity, error, lost
  - sleeping → starting, restoring, stopped, error, lost (wake re-enters the start
    lane; #203 — restore returns the row to `:sleeping` without waking it,
    ADR-0037 §5; `stopped` is the sleep path's honest landing when the
    gateway serve rewrite fails, #273 — owner Start still works)
  - stopped → starting, restoring, error, lost
  - restoring → starting, stopped, sleeping, error, lost (#222, ADR-0037
    §5: back to the pre-restore state, or into the start lane when the
    app was running — the reconciler lands `:running`)
  - error → deploying, starting, running, no_capacity, restoring, lost
    (#776: a stale failure whose workload is healthy recovers to
    `:running`; an unschedulable pod reads as `:no_capacity`)
  - no_capacity → stopped, starting, running, error, lost (#776:
    capacity is a waiting state; the owner may stop it (the exit to
    resize down), the pod schedules → `:starting`, ready → `:running`,
    a real failure → `:error`, a vanished namespace → `:lost`)
  - lost → deploying (the re-deploy path; teardown rides `:deleting`
    from anywhere)

  `:error` and `:deleting` are enterable from any state (failure
  recovery; a row can always be torn down). `running → starting` is
  deliberately absent — the reconciler must not churn on transient
  readiness blips. The reconciler is the only writer of `:running`;
  `deploy`/`start` land in `:starting` and readiness confirms the rest.
  `:lost` (#196) enters only from deployed states — `:deploying` is the
  deploy job's own failure lane, `:pending` has nothing to lose.
  `:sleeping` (#203, ADR-0036) enters only from `:running` (the idle
  sweep never races a half-built instance) and leaves the same way
  `:stopped` does — wake is `start`, stranded is `:lost`.

  `:restoring` (#222, ADR-0037 §5) is the restore's exclusive hold on the
  instance: it enters only from a state that already has a volume to
  write over (`:running`, `:stopped`, `:sleeping`) — or from `:error`
  when the error IS a failed restore (`:restore_failed`; the retry is
  the owner's way out, the operation's guard is the scope) — and
  leaves for the state the restore found it in — plus `:starting`
  when it found the app running, so the reconciler re-confirms
  readiness instead of the restore inventing `:running` (the
  reconciler-only-writer rule holds).
  """

  use Ash.Resource.Validation

  alias Ash.Changeset
  alias Ash.Resource.Validation

  @valid_transitions %{
    pending: [:deploying, :error],
    deploying: [:starting, :error],
    starting: [:running, :no_capacity, :error, :lost],
    running: [:stopped, :sleeping, :restoring, :no_capacity, :error, :lost],
    sleeping: [:starting, :restoring, :stopped, :error, :lost],
    stopped: [:starting, :restoring, :error, :lost],
    # #222 (ADR-0037 §5): restore releases into the state it found — the
    # pre-restore one, or :starting so the reconciler re-confirms
    # readiness (it stays the only writer of :running).
    restoring: [:starting, :stopped, :sleeping, :error, :lost],
    # :restoring here is the failed-restore RETRY (ADR-0037 §5): the
    # operation's guard admits only :error rows whose failure_reason is
    # :restore_failed — the table cannot see the reason, so the op's
    # guard is the scope and this edge is the door. :running is the
    # stale-failure recovery (#776); :no_capacity is capacity, not a
    # crash. The reconciler's failure_reason gate keeps intent-bearing
    # errors (stop/restore/teardown) out of both.
    error: [:deploying, :starting, :running, :no_capacity, :restoring, :lost],
    # #776: waiting for the scheduler. The owner can stop it (then resize
    # down), a scheduled pod returns to the start lane, ready lands
    # :running; a real failure/capacity loss exits through :error/:lost.
    no_capacity: [:stopped, :starting, :running, :error, :lost],
    # Entered from any state (async teardown); its only exit on retry
    # exhaustion is :error (mark_teardown_error). A successful teardown
    # hard-deletes the row instead of transitioning.
    deleting: [:error],
    # #196: externally-deleted namespace. Re-deploy is the only funnel
    # exit (the :deploy action force-changes past this validation, but
    # the map stays the machine's source of truth); teardown rides
    # :deleting-from-anywhere.
    lost: [:deploying]
  }

  @doc """
  The transition table — one writer (this validator). Read by
  FluxVale.PromEx.Plugins.Business to derive the fleet's 51-pair
  ceiling; the catch-all arms (any → :error / any → :deleting) are
  validate/2 arms, not map entries, so the derivation adds them.
  """
  @spec valid_transitions() :: %{atom() => [atom()]}
  def valid_transitions, do: @valid_transitions

  @impl Validation
  def init(_opts), do: {:ok, []}

  @impl Validation
  def validate(changeset, _opts, _context) do
    old_status = changeset.data.status
    new_status = Changeset.get_attribute(changeset, :status)

    cond do
      # coveralls-ignore-next-line - unreachable: status is allow_nil? false
      is_nil(new_status) ->
        :ok

      # A no-op (same status) is a message-only write — allowed; the
      # anchors' enter/leave branches key on old != new, so it is inert.
      new_status == old_status ->
        :ok

      new_status == :error ->
        :ok

      new_status == :deleting ->
        :ok

      new_status in Map.get(@valid_transitions, old_status, []) ->
        :ok

      true ->
        {:error,
         field: :status,
         message:
           "Invalid status transition: cannot transition from #{old_status} to #{new_status}"}
    end
  end

  @impl Validation
  def atomic?, do: false

  @impl Validation
  def describe(_opts) do
    [
      message: "status transitions must follow the state machine",
      vars: []
    ]
  end
end
