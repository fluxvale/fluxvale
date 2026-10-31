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
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS

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
  # two halves decide against one state. The claims write committed =
  # the view's source of truth moved, so the Corefile re-renders
  # best-effort after it (ADR-0040 §4) — a failed render never fails
  # the unclaim.
  defp update_claims(gateway, domain) do
    claims = Map.delete(gateway.dns_claims || %{}, domain)

    case put_claims(gateway, domain, claims, 1) do
      {:ok, row} ->
        RenderAccessDNS.call()
        {:ok, row}

      {:error, _reason} = failure ->
        failure
    end
  end

  # One retry on StaleRecord (update_claims' optimistic lock, P2-3):
  # two tabs unclaiming two domains race, and the slower writer
  # recomputes from the committed map instead of clobbering the other's
  # entry. A second stale means the row is genuinely contended — the
  # caller's retry owns it.
  defp put_claims(gateway, domain, claims, effort) do
    case AccessGateway.update_claims(gateway, %{dns_claims: claims}, authorize?: false) do
      {:ok, row} ->
        {:ok, row}

      {:error, error} = failure ->
        maybe_retry(gateway, domain, effort, error, failure)
    end
  end

  # One retry on StaleRecord; a second stale (or a torn-down row)
  # leaves the failure standing — the caller's retry owns it.
  defp maybe_retry(gateway, domain, effort, error, failure) do
    if effort > 0 and stale_record?(error) do
      retry_on_fresh(gateway, domain, effort, failure)
    else
      failure
    end
  end

  defp retry_on_fresh(gateway, domain, effort, failure) do
    case AccessGateway.get_by_id(gateway.id, authorize?: false) do
      {:ok, fresh} ->
        put_claims(fresh, domain, Map.delete(fresh.dns_claims || %{}, domain), effort - 1)

      {:error, _gone} ->
        failure
    end
  end

  defp stale_record?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  defp stale_record?(_other), do: false
end
