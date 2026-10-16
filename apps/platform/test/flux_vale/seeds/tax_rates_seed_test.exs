defmodule FluxVale.Seeds.TaxRateSeedTest do
  @moduledoc """
  The tax-rate seed flow (`FluxVale.Seeds.seed_tax_rates!/1`) against a
  sandboxed DB — create, reprice-convergence, and idempotency (#138).
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Pricing.TaxRate
  alias FluxVale.Seeds

  require Ash.Query

  @effective_from ~U[2021-01-01 00:00:00.000000Z]

  describe "seed_tax_rates!/0 (shipped data)" do
    test "seeds the launch table cleanly, one row per YAML entry" do
      assert :ok == Seeds.seed_tax_rates!()

      shipped = Seeds.TaxRateData.entries()

      assert length(Ash.read!(TaxRate, authorize?: false)) == length(shipped)

      de = Enum.find(shipped, &(&1.country == "DE"))
      assert row_rate_bp("DE", nil, de.effective_from) == 1900
    end

    test "re-seeding converges drifted rates back to the YAML" do
      assert :ok == Seeds.seed_tax_rates!()

      shipped = Seeds.TaxRateData.entries()
      de = Enum.find(shipped, &(&1.country == "DE"))

      [row] = find_rows("DE", nil, de.effective_from)
      TaxRate.update!(row, %{rate_bp: 999}, authorize?: false)

      assert :ok == Seeds.seed_tax_rates!()

      assert row_rate_bp("DE", nil, de.effective_from) == 1900
    end

    test "re-seeding produces no duplicates" do
      assert :ok == Seeds.seed_tax_rates!()
      assert :ok == Seeds.seed_tax_rates!()

      shipped = Seeds.TaxRateData.entries()

      assert length(Ash.read!(TaxRate, authorize?: false)) == length(shipped)
    end
  end

  describe "seed_tax_rates!/1 (explicit entries)" do
    test "creates entries it has not seen — country-wide and state rows" do
      entries = [
        %{country: "DE", state: nil, rate_bp: 1900, effective_from: @effective_from},
        %{
          country: "US",
          state: "CA",
          rate_bp: 800,
          effective_from: ~U[2026-01-01 00:00:00.000000Z]
        }
      ]

      assert :ok == Seeds.seed_tax_rates!(entries)

      assert row_rate_bp("DE", nil, @effective_from) == 1900
      assert row_rate_bp("US", "CA", ~U[2026-01-01 00:00:00.000000Z]) == 800
    end

    test "converges an existing row's rate without duplicating it" do
      entries = [%{country: "DE", state: nil, rate_bp: 1900, effective_from: @effective_from}]
      assert :ok == Seeds.seed_tax_rates!(entries)

      assert :ok ==
               Seeds.seed_tax_rates!([
                 %{country: "DE", state: nil, rate_bp: 2000, effective_from: @effective_from}
               ])

      assert row_rate_bp("DE", nil, @effective_from) == 2000
      assert length(find_rows("DE", nil, @effective_from)) == 1
    end

    test "a country-wide row and a same-date state row are distinct rows" do
      entries = [
        %{country: "US", state: nil, rate_bp: 0, effective_from: @effective_from},
        %{country: "US", state: "CA", rate_bp: 800, effective_from: @effective_from}
      ]

      assert :ok == Seeds.seed_tax_rates!(entries)

      assert [%{rate_bp: 0}] = find_rows("US", nil, @effective_from)
      assert [%{rate_bp: 800}] = find_rows("US", "CA", @effective_from)
    end
  end

  defp find_rows(country, state, effective_from) do
    base = Ash.Query.filter(TaxRate, country == ^country and effective_from == ^effective_from)

    query =
      if state do
        Ash.Query.filter(base, state == ^state)
      else
        Ash.Query.filter(base, is_nil(state))
      end

    Ash.read!(query, authorize?: false)
  end

  defp row_rate_bp(country, state, effective_from) do
    case find_rows(country, state, effective_from) do
      [%{rate_bp: rate_bp}] ->
        rate_bp

      other ->
        flunk("expected exactly one row for #{country}/#{state}, got #{inspect(other)}")
    end
  end
end
