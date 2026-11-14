defmodule FluxVale.Infrastructure.AccessGateway.ClaimedDomains do
  @moduledoc """
  The gateway's claimed domain NAMES (#771) — the machine-readable half
  of the claim state the custom-domain tool reports.

  `dns_claims` stays private: its values (resolver IPs, tailnet
  internals, the last-observed hash) never ride the wire. The keys are
  already public through the org's domain registry, so exposing just
  the names gives the agent an honest claimed/unclaimed answer without
  widening the trust surface.
  """

  use Ash.Resource.Calculation

  @impl Ash.Resource.Calculation
  def load(_query, _opts, _context), do: [:dns_claims]

  @impl Ash.Resource.Calculation
  def calculate(records, _opts, _context) do
    Enum.map(records, fn gateway ->
      case gateway.dns_claims do
        %{} = claims ->
          claims
          |> Map.keys()
          |> Enum.sort()

        _other ->
          []
      end
    end)
  end
end
