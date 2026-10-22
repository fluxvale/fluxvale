defmodule FluxVale.Infrastructure.Instance.StatusTransition do
  @moduledoc """
  Validation for Instance status transitions (ADR-0005 state machine).

  Enforces valid transitions:

  - pending → deploying, error
  - deploying → starting, error
  - starting → running, error, lost
  - running → stopped, error, lost
  - stopped → starting, error, lost
  - error → deploying, starting, lost
  - lost → deploying (the re-deploy path; teardown rides `:deleting`
    from anywhere)

  `:error` and `:deleting` are enterable from any state (failure
  recovery; a row can always be torn down). `running → starting` is
  deliberately absent — the reconciler must not churn on transient
  readiness blips. The reconciler is the only writer of `:running`;
  `deploy`/`start` land in `:starting` and readiness confirms the rest.
  `:lost` (#196) enters only from deployed states — `:deploying` is the
  deploy job's own failure lane, `:pending` has nothing to lose.
  """

  use Ash.Resource.Validation

  alias Ash.Changeset
  alias Ash.Resource.Validation

  @valid_transitions %{
    pending: [:deploying, :error],
    deploying: [:starting, :error],
    starting: [:running, :error, :lost],
    running: [:stopped, :error, :lost],
    stopped: [:starting, :error, :lost],
    error: [:deploying, :starting, :lost],
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
