defmodule FluxVale.Infrastructure.AccessGateway.ProvisionCluster do
  @moduledoc """
  Materializes a gateway's cluster objects (ADR-0039 §1/§4) — the
  `create` action's synchronous leg, and the `:provision` trigger's
  body for the re-paste/redeploy recovery.

  Order matters and is the contract: the row is written first (the
  `create` action's own write, before this `after_action` runs), so a
  cluster failure leaves a row the panel can show and the retry can
  heal. A pod with no row would be an ungovernable object no sweep
  could find.

  The provider does the work; this module owns only the transition.
  Landing `:provisioning` is honest — the Deployment exists but has not
  reported ready — and `gateway_status` (the observed-state write) is
  the single promoter to `:active`.
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider

  require Logger

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    # The create action's own argument, when there is one: the ordinary
    # opt-in path never reads the key back, and never needs a cluster
    # round-trip to get it.
    argument_key = Ash.Changeset.get_argument(changeset, :auth_key)

    Ash.Changeset.after_action(changeset, fn _changeset, gateway ->
      case provision(gateway, argument_key) do
        :ok -> {:ok, gateway}
        {:error, reason} = error -> fail(gateway, reason, error)
      end
    end)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (cluster I/O in the hook)
  def atomic?, do: false

  defp provision(%AccessGateway{} = gateway, auth_key)
       when is_binary(auth_key) and auth_key != "" do
    run(gateway, auth_key)
  end

  # The trigger's retry has no create argument: it reads the Secret the
  # first attempt wrote (internal only — never a user surface).
  defp provision(%AccessGateway{} = gateway, _absent) do
    case credential(gateway) do
      {:ok, auth_key} -> run(gateway, auth_key)
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(%AccessGateway{} = gateway, auth_key) do
    case AccessProvider.impl_for(gateway).provision_gateway(gateway, auth_key) do
      {:ok, _provisioned} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The key is a create argument, not a column — the trigger's retry
  # re-reads it from the Secret the first attempt wrote. A missing
  # Secret means the first attempt never got that far, so the row needs
  # a fresh paste (the panel's action), which is a real answer rather
  # than a guess about a key we do not have.
  defp credential(gateway) do
    case AccessProvider.impl_for(gateway).read_credential(gateway) do
      {:ok, auth_key} -> {:ok, auth_key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fail(gateway, reason, error) do
    Logger.error("Access gateway #{gateway.id} provisioning failed: #{inspect(reason)}")
    error
  end
end
