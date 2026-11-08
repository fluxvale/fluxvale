defmodule FluxVale.Pricing.Operations.PriceAllocationBeyondThresholdTest do
  @moduledoc """
  The beyond-threshold storage rule (#250, ADR-0046): the first
  `threshold_gb` price on the v5 curve exactly as before; each GB above
  bills at the configured marginal rate, never multiplied by the
  regional surcharge. Pins the boundary (docs/pricing-calibration.md),
  the config↔ladder parity gate, and that configuration owns the
  behaviour.
  """

  # async: false — the override test flips global app env (the
  # stub_build_sha posture: capture, flip, restore on exit).
  use ExUnit.Case, async: false

  alias FluxVale.Pricing.Operations.PriceAllocation
  alias FluxValeWeb.AllocationSliders

  describe "calibration: the threshold boundary" do
    test "at the threshold the v5 curve is unchanged (100 GB = 228¢)" do
      assert PriceAllocation.storage_cents(100, :nuremberg) == 228
    end

    test "just above the threshold adds one marginal GB (101 GB = 231¢)" do
      assert PriceAllocation.storage_cents(101, :nuremberg) == 231
    end

    test "200 GB = the curve at 100 plus 100 marginal GB (528¢)" do
      assert PriceAllocation.storage_cents(200, :nuremberg) == 528
    end

    test "1000 GB = the curve at 100 plus 900 marginal GB (2928¢)" do
      assert PriceAllocation.storage_cents(1_000, :nuremberg) == 2_928
    end

    test "the marginal rate is not multiplied by the regional surcharge" do
      # :singapore's curve at 100 GB is 237¢ (the B′-SG table); the
      # overage adds 3¢ flat, never 3 × 1.25.
      assert PriceAllocation.storage_cents(101, :singapore) == 240
    end
  end

  describe "configuration" do
    test "the threshold is the ladder's top storage rung (parity gate)" do
      values = AllocationSliders.storage_dimension().values

      top_rung =
        values
        |> List.last()
        |> String.to_integer()

      assert config().threshold_gb == top_rung
    end

    test "the threshold and rate move together with configuration" do
      previous = config()

      # The override threshold sits above every async-tested exact price
      # (the ladder tops at 100 GB), so the window cannot perturb another
      # module — async: false does not serialize against async suites.
      Application.put_env(:flux_vale, :storage_beyond_threshold, %{
        threshold_gb: 1_000,
        cents_per_gb: 10,
        max_gb: 7_600
      })

      on_exit(fn -> Application.put_env(:flux_vale, :storage_beyond_threshold, previous) end)

      # At the overridden threshold the curve still owns the price…
      assert PriceAllocation.storage_cents(1_000, :nuremberg) == 1_280
      # …and each GB above bills the overridden marginal rate.
      assert PriceAllocation.storage_cents(1_001, :nuremberg) == 1_290
      assert PriceAllocation.storage_cents(2_000, :nuremberg) == 11_280
    end
  end

  defp config, do: Application.fetch_env!(:flux_vale, :storage_beyond_threshold)
end
