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
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS

  require Logger

  @doc """
  `{:ok, gateway}` (the row with its updated `dns_claims`) or
  `{:error, reason}` — `reason` being Forbidden, `:gateway_not_serving`,
  `:org_mismatch`, `:domain_not_verified`, `:resolver_unconfigured`, the
  provider's claim reason (`:no_api_token`, `:node_not_found`,
  `:node_ambiguous`, `:unauthorized`, `:forbidden`, …) or the
  claims-write failure. `opts` carry `actor:` / `authorize?:`.

  `opts[:render]` (default true) suppresses the post-claims CoreDNS
  re-render, for the nested system caller: the S6 resume runs this
  operation INSIDE its own transaction, where the claims write is not
  yet committed — rendering here would put uncommitted claims into the
  ConfigMap (the S4 lesson). The resume renders once itself, in its
  `after_transaction`, on the committed row only.
  """
  @spec call(AccessGateway.t(), AccessDomain.t(), keyword()) ::
          {:ok, AccessGateway.t()} | {:error, term()}
  def call(%AccessGateway{} = gateway, %AccessDomain{} = domain, opts \\ []) do
    actor = opts[:actor]
    authorize? = Keyword.get(opts, :authorize?, true)
    render? = Keyword.get(opts, :render, true)

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
      land(result, gateway, domain, resolver_ip, render?)
    end
  end

  # Success: the row's claims gain (or update) the entry — the registry
  # the unclaim's shared-tailnet rule reads. The entry records WHAT was
  # claimed AND the tailnet suffix the owner had typed at claim time
  # (P2-14): the recorded value, not a live re-read of the row, is what
  # the shared-tailnet matching uses forever after. authorize?: false —
  # this operation's authorization already happened on the reads above.
  # The claims write committed = the view's source of truth moved, so the
  # Corefile re-renders best-effort after it (ADR-0040 §4's derived-state
  # stance) — a failed render never fails the claim.
  defp land({:ok, _claimed}, gateway, domain, resolver_ip, render?) do
    claims =
      Map.put(gateway.dns_claims || %{}, domain.domain, %{
        "ip" => resolver_ip,
        "tailnet" => gateway.tailnet_domain
      })

    case put_claims(gateway, domain.domain, claims, 1) do
      {:ok, row} ->
        if render? do
          RenderAccessDNS.call()
        end

        {:ok, row}

      {:error, _reason} = failure ->
        failure
    end
  end

  defp land({:error, kind} = error, gateway, _domain, _resolver_ip, _render?)
       when kind in [:unauthorized, :forbidden] do
    drift_to_needs_attention(gateway, kind)
    error
  end

  defp land({:error, _reason} = error, _gateway, _domain, _resolver_ip, _render?), do: error

  # A racing claims write (two tabs, two domains) fails StaleRecord
  # under update_claims' optimistic lock — the retry re-reads the
  # committed map and recomputes, so the second write MERGES instead of
  # clobbering (P2-3's lost-update). One retry: the second read is the
  # committed row; a second stale means the row is genuinely contended
  # and the owner's retry owns it.
  defp put_claims(gateway, domain, claims, effort) do
    case AccessGateway.update_claims(gateway, %{dns_claims: claims}, authorize?: false) do
      {:ok, row} ->
        {:ok, row}

      {:error, error} = failure ->
        maybe_retry(gateway, domain, claims, effort, error, failure)
    end
  end

  # One retry on StaleRecord; a second stale (or a torn-down row)
  # leaves the failure standing — the owner's retry owns it.
  defp maybe_retry(gateway, domain, claims, effort, error, failure) do
    if effort > 0 and stale_record?(error) do
      retry_on_fresh(gateway, domain, claims, effort, failure)
    else
      failure
    end
  end

  defp retry_on_fresh(gateway, domain, claims, effort, failure) do
    case AccessGateway.get_by_id(gateway.id, authorize?: false) do
      {:ok, fresh} ->
        merged = Map.put(fresh.dns_claims || %{}, domain, Map.get(claims, domain))
        put_claims(fresh, domain, merged, effort - 1)

      {:error, _gone} ->
        failure
    end
  end

  defp stale_record?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  defp stale_record?(_other), do: false

  defp drift_to_needs_attention(gateway, kind) do
    case AccessGateway.update_state(
           gateway,
           %{
             state: :needs_attention,
             status_message: AccessProvider.impl_for(gateway).token_drift_message(kind),
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
