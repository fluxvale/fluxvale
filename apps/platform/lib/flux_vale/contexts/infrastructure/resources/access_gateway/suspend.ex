defmodule FluxVale.Infrastructure.AccessGateway.Suspend do
  @moduledoc """
  The zero-balance ladder's gateway arm (#268's must-fix, ADR-0039 §5):
  scale the pod to 0, land `:suspended`, park the settlement anchor.

  `:suspended` accrues nothing — `PerformSettle` books only `:active`
  rows, and parking `metering_since` means the suspended interval is not
  billed on resume either. The pod, its Secret and its PVC stay: a
  resume is a scale-up, and the node identity survives, which is the
  difference between "paused for non-payment" and "re-provisioned".

  The instances stay attached. Their routes point at a gateway that is
  not running, so a visitor gets a dead tailnet address — honest, and
  the panel says why (the balance copy, not an access error). Detaching
  on suspend would silently rewrite the owner's configuration for a
  billing event, which is not this arm's business.
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.AccessProvider

  require Logger

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      gateway = changeset.data

      # Idempotent: the ladder re-enters this arm every hour while the
      # balance stays ≤ 0 (the sweep's abandoned-org stance). Nothing to
      # do, nothing to write.
      if gateway.state == :suspended do
        changeset
      else
        case AccessProvider.impl_for(gateway).scale_gateway(gateway, 0) do
          :ok ->
            changeset
            |> Ash.Changeset.force_change_attribute(:state, :suspended)
            |> Ash.Changeset.force_change_attribute(
              :status_message,
              "Access paused — top up to resume"
            )
            # Park the cursor: the suspended interval must not bill on
            # resume (the instance running-anchor fold, same reasoning).
            |> Ash.Changeset.force_change_attribute(:metering_since, nil)

          {:error, reason} ->
            Logger.error("Access gateway #{gateway.id} suspend failed: #{inspect(reason)}")
            Ash.Changeset.add_error(changeset, message: "Couldn't pause access")
        end
      end
    end)
  end

  # Not idempotent as a whole: it writes a row after cluster I/O.
  @impl Ash.Resource.Change
  def atomic?, do: false
end
