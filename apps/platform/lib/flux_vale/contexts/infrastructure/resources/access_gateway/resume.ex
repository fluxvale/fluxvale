defmodule FluxVale.Infrastructure.AccessGateway.Resume do
  @moduledoc """
  The owner's funded resume after a balance suspension (ADR-0039 §5):
  scale the pod back to 1, land `:provisioning`, reopen the settlement
  anchor.

  `:provisioning`, not `:active`: the platform has not observed the pod
  ready, and only `gateway_status` may claim `:active` (the
  observed-state rule). The panel shows "Setting up access" for the few
  seconds until the next observation.

  The anchor reopens at `now` — the suspended interval is not billed
  (Suspend parked it), and the resume starts a fresh accrual window.

  **Ordering is load-bearing: the row commits before the scale.** The
  scale runs in `after_action`, so a failure aborts the action and rolls
  the row back to `:suspended` — nothing serving, nothing billed, owner
  can retry. Scaling first would be the opposite hazard: a row write that
  then failed would leave `:suspended` while the pod ran, and NOTHING
  retries that — the ladder skips `:suspended` and the observer refuses
  to override a suspension, so the gateway would serve free forever.

  (Suspend is the mirror and needs the opposite order: it scales first,
  and a failed row write self-heals because the ladder keeps selecting
  `:active` at ≤ 0 and re-enters. Resume has no such re-entry.)
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias FluxVale.Infrastructure.AccessProvider

  require Logger

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      gateway = changeset.data

      # Only a suspended gateway resumes; a double-click is a no-op, not
      # a second scale.
      if gateway.state == :suspended do
        resume(gateway, changeset)
      else
        changeset
      end
    end)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (cluster I/O in the hook)
  def atomic?, do: false

  # The scale is cluster I/O in `after_action`, so its failure must abort
  # the action (which rolls the row's write back) rather than be swallowed.
  defp resume_error do
    InvalidAttribute.exception(field: :state, message: "Couldn't resume access")
  end

  # Row first, scale second (see the moduledoc). `after_action` returning
  # an error rolls the row's own write back, so a failed scale leaves the
  # gateway exactly as it was.
  defp resume(gateway, changeset) do
    changeset
    # The observer's expected_state pattern: the UPDATE lands only on a
    # still-:suspended row, so a concurrent writer (a second resume, the
    # teardown) turns this write into a StaleRecord instead of a blind
    # overwrite — the after_action scale never runs on a row we didn't
    # win, and the anchor cannot restart twice. The guard above still
    # reads the struct: it is the cheap no-op for a caller whose own
    # view is already out of :suspended.
    |> Ash.Changeset.filter(state: :suspended)
    |> Ash.Changeset.force_change_attribute(:state, :provisioning)
    |> Ash.Changeset.force_change_attribute(:status_message, "Reconnecting access")
    |> Ash.Changeset.force_change_attribute(:metering_since, DateTime.utc_now())
    |> Ash.Changeset.after_action(fn _changeset, resumed ->
      case AccessProvider.impl_for(resumed).scale_gateway(resumed, 1) do
        :ok ->
          {:ok, resumed}

        {:error, reason} ->
          Logger.error("Access gateway #{gateway.id} resume failed: #{inspect(reason)}")

          {:error, resume_error()}
      end
    end)
  end
end
