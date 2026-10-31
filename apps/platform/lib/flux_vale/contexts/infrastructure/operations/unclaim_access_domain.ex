defmodule FluxVale.Infrastructure.Operations.UnclaimAccessDomain do
  @moduledoc """
  Un-claims a domain from the gateway's tailnet (ADR-0040 §3, the
  claim's mirror): the provider removes the split-DNS route (shared
  tailnets keep it while another gateway still claims) and drops the
  /32 once this gateway's last claim is gone; the row's `dns_claims`
  loses the entry through the system funnel.

  Member-scoped like the claim: ownership is enforced by the authorized
  reads (gateway AND domain), so a non-member is Forbidden before any
  API call. A parked gateway unclaims fine — the tailnet work is API
  side, not pod side. A provider failure leaves the row's claims
  untouched (the retry converges).
  """

  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider

  @doc """
  `{:ok, gateway}` (the row with its updated `dns_claims`) or
  `{:error, reason}` — Forbidden, the provider's unclaim reason, or the
  claims-write failure. `opts` carry `actor:` / `authorize?:`.
  """
  @spec call(AccessGateway.t(), AccessDomain.t(), keyword()) ::
          {:ok, AccessGateway.t()} | {:error, term()}
  def call(%AccessGateway{} = gateway, %AccessDomain{} = domain, opts \\ []) do
    actor = opts[:actor]
    authorize? = Keyword.get(opts, :authorize?, true)

    with {:ok, gateway} <-
           AccessGateway.get_by_id(gateway.id, actor: actor, authorize?: authorize?),
         {:ok, domain} <-
           AccessDomain.get_by_id(domain.id, actor: actor, authorize?: authorize?),
         :ok <- ensure_same_org(gateway, domain),
         :ok <- AccessProvider.impl_for(gateway).unclaim_domain(gateway, domain.domain) do
      update_claims(gateway, domain.domain)
    end
  end

  defp ensure_same_org(%AccessGateway{organization_id: org_id}, %AccessDomain{
         organization_id: org_id
       }),
       do: :ok

  defp ensure_same_org(_gateway, _domain), do: {:error, :org_mismatch}

  # authorize?: false — the operation's authorization already happened
  # on the reads above. The claims update reads the STALE struct's map
  # (the provider's shared-tailnet decision used the same view), so the
  # two halves decide against one state.
  defp update_claims(gateway, domain) do
    claims = Map.delete(gateway.dns_claims || %{}, domain)

    case AccessGateway.update_claims(gateway, %{dns_claims: claims}, authorize?: false) do
      {:ok, row} -> {:ok, row}
      {:error, _reason} = error -> error
    end
  end
end
