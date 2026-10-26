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
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.AccessProvider

  require Logger

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      gateway = changeset.data

      # Only a suspended gateway resumes; the action's guard is the
      # arbiter so a double-click is a no-op, not a second scale.
      if gateway.state == :suspended do
        case AccessProvider.impl_for(gateway).scale_gateway(gateway, 1) do
          :ok ->
            changeset
            |> Ash.Changeset.force_change_attribute(:state, :provisioning)
            |> Ash.Changeset.force_change_attribute(:status_message, "Reconnecting access")
            |> Ash.Changeset.force_change_attribute(:metering_since, DateTime.utc_now())

          {:error, reason} ->
            Logger.error("Access gateway #{gateway.id} resume failed: #{inspect(reason)}")
            Ash.Changeset.add_error(changeset, message: "Couldn't resume access")
        end
      else
        changeset
      end
    end)
  end

  @impl Ash.Resource.Change
  def atomic?, do: false
end
