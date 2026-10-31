defmodule FluxVale.Infrastructure.Operations.ClaimAccessDomain do
  @moduledoc """
  Claims a verified domain on the gateway's tailnet (ADR-0040 §3): the
  member-scoped entry to the provider's claim — subnet-route approval
  plus the split-DNS route pointing at the FluxVale resolver (the IP
  from config `:access_dns`).

  Gates, in order: the gateway is a serving state (`:active`,
  `:provisioning`, `:needs_attention` — parked or dying gateways claim
  nothing), the domain is the org's own and `:verified` (verify-by-
  issuance, ADR-0040 §2 — an unverified domain claims nothing), and the
  resolver is configured. Then the provider's claim, then the row's
  `dns_claims` gains/updates the entry through the system funnel.

  **The 401 is the drift signal (§5):** a rejected token — expired or
  revoked, they present identically — drifts the row to
  `:needs_attention` with the re-paste copy (through the same
  `:update_state` funnel the observer writes) AND fails the operation
  honestly. No silent claim, no retry storm: the owner pastes a fresh
  token, the next claim or observe pass converges.
  """

  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider

  require Logger

  # The copy that names the API token; expired and revoked present
  # identically (§5). The same copy is pinned in the Tailscale
  # provider's observer drift — keep the two in sync.
  @token_rejected_copy "Your Tailscale API key was rejected — paste a fresh one"

  @doc """
  `{:ok, gateway}` (the row with its updated `dns_claims`) or
  `{:error, reason}` — `reason` being Forbidden, `:gateway_not_serving`,
  `:org_mismatch`, `:domain_not_verified`, `:resolver_unconfigured`, the
  provider's claim reason (`:no_api_token`, `:node_not_found`,
  `:unauthorized`, …) or the claims-write failure. `opts` carry
  `actor:` / `authorize?:`.
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
         :ok <- ensure_serving(gateway),
         :ok <- ensure_verified(domain),
         {:ok, resolver_ip} <- resolver_ip(),
         result <-
           AccessProvider.impl_for(gateway).claim_domain(gateway, domain.domain, resolver_ip) do
      land(result, gateway, domain.domain, resolver_ip)
    end
  end

  # Success: the row's claims gain (or update) the entry — the registry
  # the unclaim's shared-tailnet rule reads. authorize?: false: this
  # operation's authorization already happened on the reads above.
  defp land({:ok, _claimed}, gateway, domain, resolver_ip) do
    claims = Map.put(gateway.dns_claims || %{}, domain, resolver_ip)

    case AccessGateway.update_claims(gateway, %{dns_claims: claims}, authorize?: false) do
      {:ok, row} -> {:ok, row}
      {:error, _reason} = error -> error
    end
  end

  # The drift: row first (best-effort — the observer's next pass is the
  # backstop if this write fails), then the honest failure. The row's
  # claims are untouched: nothing was claimed.
  defp land({:error, :unauthorized} = error, gateway, _domain, _resolver_ip) do
    drift_to_needs_attention(gateway)
    error
  end

  defp land({:error, _reason} = error, _gateway, _domain, _resolver_ip), do: error

  defp drift_to_needs_attention(gateway) do
    case AccessGateway.update_state(
           gateway,
           %{
             state: :needs_attention,
             status_message: @token_rejected_copy,
             needs_attention_since: DateTime.utc_now()
           },
           authorize?: false
         ) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Access gateway #{gateway.id} token-drift write failed (observer is the backstop): " <>
            inspect(reason)
        )

        :ok
    end
  end

  defp ensure_same_org(%AccessGateway{organization_id: org_id}, %AccessDomain{
         organization_id: org_id
       }),
       do: :ok

  # A member of two orgs passes both authorized reads (the platform
  # domain is per-org); the claim is still refused — one org's gateway
  # never claims another org's row.
  defp ensure_same_org(_gateway, _domain), do: {:error, :org_mismatch}

  defp ensure_serving(%AccessGateway{state: state})
       when state in [:active, :provisioning, :needs_attention],
       do: :ok

  defp ensure_serving(%AccessGateway{state: _parked}), do: {:error, :gateway_not_serving}

  defp ensure_verified(%AccessDomain{state: :verified}), do: :ok
  defp ensure_verified(%AccessDomain{state: _unverified}), do: {:error, :domain_not_verified}

  defp resolver_ip do
    case Application.get_env(:flux_vale, :access_dns) do
      config when is_list(config) ->
        {:ok, Keyword.fetch!(config, :resolver_ip)}

      # Local stacks: no resolver, nothing to claim against — refused
      # honestly rather than guessed.
      _unset ->
        {:error, :resolver_unconfigured}
    end
  end
end
