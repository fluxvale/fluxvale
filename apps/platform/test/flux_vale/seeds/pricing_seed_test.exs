defmodule FluxVale.Seeds.PricingSeedTest do
  @moduledoc """
  The pricing seed flow (`FluxVale.Seeds.seed_pricing!/1`) against a
  sandboxed DB — create, reprice-convergence, and idempotency (#125).
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Pricing.Size
  alias FluxVale.Seeds

  describe "seed_pricing!/0 (shipped data)" do
    test "seeds the six sizes cleanly" do
      assert :ok == Seeds.seed_pricing!()

      small = Size.get_by_slug!("small", authorize?: false)

      assert Decimal.equal?(small.cpu_cores, Decimal.new("0.5"))
      assert small.memory_mb == 512
      assert small.storage_gb == 10
      assert small.monthly_cents == 279
      assert small.stopped_monthly_cents == 34
    end

    test "re-seeding converges drifted prices back to the YAML" do
      assert :ok == Seeds.seed_pricing!()

      small = Size.get_by_slug!("small", authorize?: false)
      Size.update!(small, %{monthly_cents: 999}, authorize?: false)

      assert :ok == Seeds.seed_pricing!()

      assert Size.get_by_slug!("small", authorize?: false).monthly_cents == 279
    end

    test "re-seeding produces no duplicates" do
      assert :ok == Seeds.seed_pricing!()
      assert :ok == Seeds.seed_pricing!()

      assert length(Ash.read!(Size, authorize?: false)) == 6
    end
  end

  describe "seed_pricing!/1 (explicit entries)" do
    test "creates an entry it has not seen" do
      entries = [
        %{
          slug: "tiny-#{System.unique_integer()}",
          cpu_cores: Decimal.new("0.25"),
          memory_mb: 512,
          storage_gb: 5,
          monthly_cents: 236,
          stopped_monthly_cents: 20
        }
      ]

      assert :ok == Seeds.seed_pricing!(entries)

      assert Size.get_by_slug!(hd(entries).slug, authorize?: false).monthly_cents == 236
    end
  end
end
