defmodule FluxVale.Pricing.Operations.ResolveTaxRate do
  @moduledoc """
  Resolves the VAT rate a checkout charges (#138, ADR-0029 Am. 3 gate 2):
  the latest `FluxVale.Pricing.TaxRate` row with `effective_from <= time`
  for the billing country; a state-specific row beats the country-wide
  one; no row (or a charge time before the first row) is 0% — never an
  error on good input, an unpriced market is a priced-at-zero market.

  `state` is the US state code; nil asks for country-wide only. Returns
  integer basis points (20% = 2000). The reverse-charge zeroing happens
  upstream (the caller knows the buyer type); this is the pure table
  lookup.

  System operation, `authorize?: false` — the rate table is signed-in-
  readable business data and the caller (checkout) is already behind the
  actor gate; the resolution feeds a price display, not an actor intent.
  """

  alias FluxVale.Pricing.TaxRate

  require Ash.Query

  @spec call(String.t(), String.t() | nil, DateTime.t()) :: non_neg_integer()
  def call(country, state \\ nil, time \\ DateTime.utc_now()) do
    resolved =
      if is_nil(state) do
        resolve(country, nil, time)
      else
        # A state-specific row beats the country-wide one; no state row
        # falls back to it.
        case resolve(country, state, time) do
          nil -> resolve(country, nil, time)
          rate_bp -> rate_bp
        end
      end

    resolved || 0
  end

  defp resolve(country, state, time) do
    query =
      TaxRate
      |> Ash.Query.filter(country == ^country and effective_from <= ^time)
      |> state_filter(state)
      |> Ash.Query.sort(effective_from: :desc)
      |> Ash.Query.limit(1)

    # read!: a DB outage is a crash, not a rate answer — only the
    # good-input miss (no row) resolves to 0.
    case Ash.read!(query, authorize?: false) do
      [%{rate_bp: rate_bp} | _rest] -> rate_bp
      # No row at or before the charge time — 0%, not an error.
      [] -> nil
    end
  end

  defp state_filter(query, nil), do: Ash.Query.filter(query, is_nil(state))
  defp state_filter(query, state), do: Ash.Query.filter(query, state == ^state)
end
