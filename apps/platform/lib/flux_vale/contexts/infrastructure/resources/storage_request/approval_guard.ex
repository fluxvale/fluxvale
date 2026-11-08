defmodule FluxVale.Infrastructure.StorageRequest.ApprovalGuard do
  @moduledoc """
  The operator approval's gate (#250, ADR-0046 §3): `requested →
  approved`, with the decision recorded and **no cluster I/O** — the
  apply is the separate, retryable step.

  What the decision checks, in the order the operator can fix it:

  1. the row is still `requested` (a racing approve/reject refuses the
     slower one; the action also carries `optimistic_lock(:version)`);
  2. the instance still exists and is in a growth-legal status
     (`StorageGrowthGuard.legal_status?/1` — running/stopped/sleeping/
     error), so an instance deleted or mid-teardown is refused honestly;
  3. the target is still above the live allocation — a resize between
     request and approve makes the request stale, and the operator's
     honest move is to reject it with feedback, never a silent no-op;
  4. the cluster's default StorageClass still allows expansion (the
     live probe; `{:ok, false}` is the product boundary, a probe error
     says "try again");
  5. the org's wallet is funded — the resize's #124 gate; an unfunded
     org is rejected with feedback instead of ordering capacity for it.
  """

  use Ash.Resource.Change

  alias FluxVale.Checks.ActorOrgWalletFunded
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Instance.StorageGrowthGuard
  alias FluxVale.Infrastructure.Operations.StorageExpansion
  alias FluxVale.Infrastructure.StorageRequest

  @impl Ash.Resource.Change
  def change(changeset, _opts, context) do
    %StorageRequest{} = request = changeset.data

    cond do
      request.status != :requested ->
        Ash.Changeset.add_error(
          changeset,
          "only a requested storage request can be approved"
        )

      is_nil(context.actor) ->
        Ash.Changeset.add_error(changeset, "an operator must approve the request")

      true ->
        gate(changeset, request, context.actor)
    end
  end

  defp gate(changeset, request, actor) do
    with {:ok, instance} <- fetch_instance(request),
         :ok <- live(instance),
         :ok <- still_grows(request, instance),
         :ok <- capable(instance),
         :ok <- funded(request) do
      decide(changeset, actor)
    else
      {:error, message} -> Ash.Changeset.add_error(changeset, message)
    end
  end

  defp decide(changeset, actor) do
    changeset
    |> Ash.Changeset.force_change_attribute(:status, :approved)
    |> Ash.Changeset.force_change_attribute(:decided_by_user_id, actor.id)
    |> Ash.Changeset.force_change_attribute(:decided_at, DateTime.utc_now())
  end

  # The instance is re-read system-side (the request's own approve
  # policy already gated the operator; this is the mechanical context).
  defp fetch_instance(request) do
    case Instance.get_by_id(request.instance_id, authorize?: false) do
      {:ok, instance} -> {:ok, instance}
      {:error, _error} -> {:error, "the instance no longer exists"}
    end
  end

  defp live(instance) do
    if StorageGrowthGuard.legal_status?(instance.status) do
      :ok
    else
      {:error, "cannot approve storage for an instance in #{instance.status} state"}
    end
  end

  defp still_grows(request, instance) do
    if request.requested_gb > instance.storage_gb do
      :ok
    else
      {:error, "the instance already has #{instance.storage_gb} GB — reject this request instead"}
    end
  end

  # Only {:ok, true} opens the gate; {:ok, false} and {:error, _} refuse,
  # with distinct copy — a capability the layer lacks is a product
  # boundary, a probe that failed is a "try again".
  #
  # A nil cluster is defensive (ResolveCluster pins one at create): there
  # is no capability to read, so it refuses like a failed probe rather
  # than guessing a yes. The narrow clause is also what satisfies the
  # probe's non-nil cluster contract.
  # coveralls-ignore-start - defensive: ResolveCluster pins a cluster at
  # create, so no test can stage this row shape.
  defp capable(%Instance{cluster_id: nil}) do
    {:error, "storage expansion check failed — try again"}
  end

  # coveralls-ignore-stop
  defp capable(%Instance{cluster_id: cluster_id}) do
    case StorageExpansion.capable?(%{cluster_id: cluster_id}) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, "storage can't be expanded on this cluster yet"}
      {:error, _reason} -> {:error, "storage expansion check failed — try again"}
    end
  end

  defp funded(request) do
    if ActorOrgWalletFunded.org_funded?(request.organization_id) do
      :ok
    else
      {:error, "the organization's wallet isn't funded — top it up before approving"}
    end
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (reads another table)
  def atomic?, do: false
end
