defmodule FluxVale.Infrastructure.AccessGateway.ProvisionCluster do
  @moduledoc """
  Materializes a gateway's cluster objects (ADR-0039 §1/§4) — the
  `create` action's synchronous leg, and the `:provision` trigger's body
  for re-converging drifted objects.

  Failure posture on `create`: the row's write is in the same
  transaction as this `after_action`, so a returned error rolls the whole
  create back — a failed create leaves **no row**. That is deliberate:
  the panel never shows a half-made gateway, and the create's own error
  is the owner's answer (retry). There is nothing for a background retry
  to pick up, which is why the trigger is not auto-enqueued. The provider
  removes the credential Secret it wrote, so the rollback cannot strand a
  live tailnet key with no row to govern it.

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
      {:ok, %{credential_secret_ref: ref}} -> record_ref(gateway, ref)
      {:error, reason} -> {:error, reason}
    end
  end

  # The ref is metadata, not a credential: writing it after the cluster
  # work is what makes `credential_secret_ref` mean anything.
  defp record_ref(%AccessGateway{} = gateway, ref) do
    changeset =
      Ash.Changeset.for_update(gateway, :update_state, %{credential_secret_ref: ref},
        authorize?: false
      )

    case Ash.update(changeset) do
      {:ok, _gateway} ->
        :ok

      # coveralls-ignore-start - defensive: DB write failure on a metadata update
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
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
