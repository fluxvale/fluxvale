defmodule FluxVale.Infrastructure.Operations.RevokePocketIdKey do
  @moduledoc """
  Drops the org's PocketID key custody (#597 S2): deletes the cluster
  Secret, then the custody row, then records the `:revoked` event.
  Owner-only (SetPocketIdKey's stance — the same crown).

  Order is Secret-first like the store, for the same recovery
  property: a row-destroy that fails after the Secret is gone leaves
  a custody row whose ref points at nothing — the retry re-runs both
  limbs, the Secret delete is 404-tolerant, and the destroy
  converges. A 404 on the Secret delete is already the revoked
  posture (someone cleaned up out of band), not an error.

  Minted OIDC clients in the PocketID are NOT touched: they keep
  working (PocketID serves them independently of the admin key);
  disconnect/rotation are S5's wiring-level concerns. Revoking
  custody only ends the platform's ability to mint new ones.
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.RecordCustodyEvent
  alias FluxVale.Infrastructure.PocketIdCustody

  @doc """
  `:ok` or `{:error, reason}` — Forbidden, `:not_org_owner`,
  `:no_custody` (nothing to revoke), or the Secret/row delete
  failure. `opts` carry `actor:` / `authorize?:`.
  """
  @spec call(Instance.t(), keyword()) :: :ok | {:error, term()}
  def call(%Instance{} = instance, opts \\ []) do
    actor = opts[:actor]
    authorize? = Keyword.get(opts, :authorize?, true)

    with {:ok, instance} <- Instance.get_by_id(instance.id, actor: actor, authorize?: authorize?),
         :ok <- ensure_org_owner(instance, actor),
         {:ok, custody} <- fetch_custody(instance),
         :ok <- delete_secret(instance, custody) do
      destroy_row(instance, custody, actor)
    end
  end

  defp fetch_custody(instance) do
    case PocketIdCustody.get_by_instance(instance.id, authorize?: false) do
      {:ok, %PocketIdCustody{} = custody} -> {:ok, custody}
      _none -> {:error, :no_custody}
    end
  end

  # 404-tolerant (the teardown safe_delete stance): the Secret being
  # already gone IS the revoked posture — the row delete proceeds.
  defp delete_secret(instance, custody) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance) do
      case Secret.delete(
             kubeconfig,
             InstanceK8s.gateway_access_namespace(),
             custody.api_key_secret_ref
           ) do
        :ok -> :ok
        {:error, %Error{reason: :not_found}} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  defp destroy_row(instance, custody, actor) do
    # authorize?: false — this operation's authorization happened on
    # the read above; the revoke funnel exists for this call alone.
    case PocketIdCustody.revoke(custody, authorize?: false) do
      :ok ->
        RecordCustodyEvent.call(%{
          organization_id: instance.organization_id,
          instance_id: instance.id,
          kind: :revoked,
          actor_id: actor && actor.id
        })

      {:error, _reason} = error ->
        error
    end
  end

  # The owner's call alone — same stance, same reason, as the paste.
  defp ensure_org_owner(_instance, nil), do: {:error, :not_org_owner}

  defp ensure_org_owner(instance, actor) do
    if ActorIsOrganizationOwner.owner?(actor, %Organization{id: instance.organization_id}) do
      :ok
    else
      {:error, :not_org_owner}
    end
  end
end
