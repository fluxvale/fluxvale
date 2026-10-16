defmodule FluxVale.Pricing.Operations.ResolveTaxRateTest do
  @moduledoc """
  The checkout rate resolver (#138): latest row at or before the charge
  time, state-specific beats country-wide, no row is 0 — never an error
  on good input.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Pricing
  alias FluxVale.Pricing.TaxRate

  @jan_2024 ~U[2024-01-01 00:00:00.000000Z]
  @jan_2026 ~U[2026-01-01 00:00:00.000000Z]
  @mid_2025 ~U[2025-06-15 12:00:00.000000Z]

  defp rate!(attrs) do
    merged = Map.merge(%{effective_from: @jan_2024}, Map.new(attrs))

    TaxRate.create!(merged, authorize?: false)
  end

  describe "call/3" do
    test "a country with no row is 0% — never raises" do
      assert Pricing.resolve_tax_rate("ZZ") == 0
    end

    test "resolves the country-wide row" do
      rate!(%{country: "DE", rate_bp: 1900})

      assert Pricing.resolve_tax_rate("DE", nil, @mid_2025) == 1900
    end

    test "a charge before the first effective_from is 0%" do
      rate!(%{country: "DE", rate_bp: 1900, effective_from: @jan_2024})

      assert Pricing.resolve_tax_rate("DE", nil, ~U[2023-12-31 23:59:59.000000Z]) == 0
    end

    test "the latest row at or before the charge time wins (effective dating)" do
      rate!(%{country: "DE", rate_bp: 1900, effective_from: @jan_2024})
      rate!(%{country: "DE", rate_bp: 2100, effective_from: @jan_2026})

      assert Pricing.resolve_tax_rate("DE", nil, @mid_2025) == 1900
      assert Pricing.resolve_tax_rate("DE", nil, @jan_2026) == 2100
      assert Pricing.resolve_tax_rate("DE", nil, ~U[2027-01-01 00:00:00.000000Z]) == 2100
    end

    test "a state-specific row beats the country-wide row" do
      rate!(%{country: "US", state: nil, rate_bp: 0})
      rate!(%{country: "US", state: "CA", rate_bp: 800, effective_from: @jan_2026})

      assert Pricing.resolve_tax_rate("US", "CA", @jan_2026) == 800
    end

    test "a state without its own row falls back to country-wide" do
      rate!(%{country: "US", state: nil, rate_bp: 0})
      rate!(%{country: "US", state: "CA", rate_bp: 800, effective_from: @jan_2026})

      assert Pricing.resolve_tax_rate("US", "NY", @jan_2026) == 0
    end

    test "a state row only applies from its effective_from" do
      rate!(%{country: "US", state: nil, rate_bp: 0})
      rate!(%{country: "US", state: "CA", rate_bp: 800, effective_from: @jan_2026})

      assert Pricing.resolve_tax_rate("US", "CA", @mid_2025) == 0
    end

    test "nil state asks for country-wide only" do
      rate!(%{country: "US", state: "CA", rate_bp: 800})

      assert Pricing.resolve_tax_rate("US", nil, @mid_2025) == 0
    end

    test "state dating and country-wide dating resolve independently" do
      rate!(%{country: "US", state: nil, rate_bp: 0})
      rate!(%{country: "US", state: "CA", rate_bp: 800, effective_from: @jan_2024})
      rate!(%{country: "US", state: "CA", rate_bp: 900, effective_from: @jan_2026})

      assert Pricing.resolve_tax_rate("US", "CA", @mid_2025) == 800
      assert Pricing.resolve_tax_rate("US", "CA", @jan_2026) == 900
    end

    test "the zero-argument-friendly defaults resolve now" do
      rate!(%{country: "DE", rate_bp: 1900, effective_from: @jan_2024})

      assert Pricing.resolve_tax_rate("DE") == 1900
      assert Pricing.resolve_tax_rate("DE", nil) == 1900
    end
  end
end
