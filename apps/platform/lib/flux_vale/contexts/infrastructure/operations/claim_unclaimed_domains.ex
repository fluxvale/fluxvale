defmodule FluxVale.Infrastructure.Operations.ClaimUnclaimedDomains do
  @moduledoc """
  Claims a gateway's verified-but-unclaimed custom domains (#756) — the
  one implementation behind the three event-driven triggers:

  Callers (all event-driven): the token save (#760), the verify pass's
  promotion, and a successful instance attach (#756).

  **Event-driven on purpose.** No every-tick retry: a revoked token
  cannot re-hit the tailnet API and re-drift the gateway every 15
  minutes; the next event (a fresh token, a verification, an attach)
  is what converges.

  **Claims are external state.** A refusal (no token, gateway not
  serving, a rejected token, a tailnet error) is returned in the
  summary and logged here — never raised, never rolled back into the
  event that triggered it. The token is written, the domain stays
  verified, the attach stands; the member-facing unclaimed line is the
  honest signal, and the next event (or a fresh token) converges.
  """

  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.Operations.ClaimAccessDomain
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS

  require Ash.Query
  require Logger

  @doc """
  `%{claimed: [domain], failed: [{domain | :sweep, reason}]}`.

  `opts[:domains]` narrows the sweep to the given rows (a caller that
  just promoted one); the default is every verified custom domain of
  the gateway's org. `opts[:render?]` (default true) suppresses the
  post-claim resolver render for callers that render once themselves.
  `opts[:actor]` attributes the claims' audit rows (the owner whose
  action caused them).
  """
  @spec call(AccessGateway.t()) :: %{
          claimed: [String.t()],
          failed: [{String.t() | :sweep, term()}]
        }
  def call(gateway), do: call(gateway, [])

  @spec call(AccessGateway.t(), keyword()) :: %{
          claimed: [String.t()],
          failed: [{String.t() | :sweep, term()}]
        }
  def call(%AccessGateway{} = gateway, opts) do
    domains = opts[:domains] || verified_domains(gateway.organization_id)
    already = claimed_names(gateway)

    {claimed, failed} =
      domains
      |> Enum.reject(&(&1.domain in already))
      |> Enum.reduce({[], []}, fn domain, {ok, bad} ->
        case ClaimAccessDomain.call(gateway, domain,
               actor: opts[:actor],
               authorize?: false,
               render: false
             ) do
          {:ok, _gateway} ->
            {[domain.domain | ok], bad}

          {:error, reason} ->
            message = "Access gateway #{gateway.hostname}: #{domain.domain} left unclaimed"
            Logger.info("#{message}: #{inspect(reason)}")

            {ok, [{domain.domain, reason} | bad]}
        end
      end)

    if Keyword.get(opts, :render?, true) and claimed != [], do: RenderAccessDNS.call()

    %{claimed: Enum.reverse(claimed), failed: Enum.reverse(failed)}
  rescue
    # A sweep crash must not turn the triggering event into a failure:
    # the token is written, the row is verified, the pairing landed.
    error ->
      Logger.error("Access gateway #{gateway.hostname}: claim sweep crashed: #{inspect(error)}")

      %{claimed: [], failed: [{:sweep, error}]}
  end

  defp verified_domains(organization_id) do
    AccessDomain
    |> Ash.Query.filter(
      kind == :custom and state == :verified and organization_id == ^organization_id
    )
    |> Ash.read!(authorize?: false)
  end

  defp claimed_names(%{dns_claims: claims}) when is_map(claims) and not is_struct(claims),
    do: Map.keys(claims)

  defp claimed_names(_gateway), do: []
end
