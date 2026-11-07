defmodule FluxVale.Infrastructure.Instance.PricingSnapshotTest do
  @moduledoc """
  The one pricing-snapshot choice (#121/#186, extracted per #493,
  storage decoupled per #558): at the recommendation the recommended
  Size row snapshots with the storage axis added at the row's own GB,
  compute off prices by the anchor formula, a sizeless recommendation
  stays unpriced — and the clock is always a fresh now + 1 year,
  except the unpriced arm's nil.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Infrastructure.Instance.PricingSnapshot
  alias FluxVale.Pricing
  alias FluxVale.TestSupport.InstanceFixtures

  # The "small" reference (#558): 295¢ of compute class plus the 10 GB
  # storage axis at 40¢ — 335¢ running, 40¢ stopped, the same totals
  # the bundled table carried.
  @compute_cents 295
  @storage_cents 40

  test "at the recommendation: the size row's rate plus the storage axis, size_id kept" do
    version = InstanceFixtures.app_version!(monthly_cents: @compute_cents, default_storage_gb: 10)
    size = Ash.load!(version, :recommended_size, authorize?: false).recommended_size

    allocation = %{
      cpu_cores: version.default_cpu_cores,
      memory_mb: version.default_memory_mb,
      storage_gb: version.default_storage_gb
    }

    pricing = PricingSnapshot.snapshot(allocation, version, DateTime.utc_now())

    assert pricing.size_id == size.id
    assert pricing.monthly_cents == @compute_cents + @storage_cents
    assert pricing.stopped_monthly_cents == @storage_cents
    assert pricing.grandfathered_until
  end

  test "storage off the default keeps the size: the axis re-prices alone (#558)" do
    version = InstanceFixtures.app_version!(monthly_cents: @compute_cents, default_storage_gb: 10)
    size = Ash.load!(version, :recommended_size, authorize?: false).recommended_size

    allocation = %{
      cpu_cores: version.default_cpu_cores,
      memory_mb: version.default_memory_mb,
      storage_gb: 50
    }

    pricing = PricingSnapshot.snapshot(allocation, version, DateTime.utc_now())
    grown_storage = Pricing.storage_monthly_cents(50)

    assert pricing.size_id == size.id
    assert pricing.monthly_cents == @compute_cents + grown_storage
    assert pricing.stopped_monthly_cents == grown_storage
    assert pricing.grandfathered_until
  end

  test "a custom allocation: formula cents, nil size" do
    version = InstanceFixtures.app_version!(monthly_cents: @compute_cents, default_storage_gb: 10)

    allocation = %{
      cpu_cores: Decimal.new("1"),
      memory_mb: version.default_memory_mb,
      storage_gb: version.default_storage_gb
    }

    pricing = PricingSnapshot.snapshot(allocation, version, DateTime.utc_now())
    rates = Pricing.price_allocation(allocation)

    assert pricing.size_id == nil
    assert pricing.monthly_cents == rates.monthly_cents
    assert pricing.stopped_monthly_cents == rates.stopped_monthly_cents
    assert pricing.grandfathered_until
  end

  test "a sizeless version at the recommendation: unpriced — all nil" do
    # Ash.Seed! — the create/update actions require a recommended_size;
    # this is the pre-#125 drift shape (the instance_test stance).
    n = System.unique_integer()

    category =
      Category.create!(
        %{name: "Sizeless #{n}", slug: "sizeless-cat-#{n}", description: "test"},
        authorize?: false
      )

    app =
      App.create!(
        %{
          name: "Sizeless #{n}",
          slug: "sizeless-#{n}",
          tagline: "test",
          description: "test",
          category_id: category.id
        },
        authorize?: false
      )

    version =
      Ash.Seed.seed!(AppVersion, %{
        version: "1.0.0",
        image: "registry.example.com/app:1.0",
        port: 3000,
        default_cpu_cores: Decimal.new("0.5"),
        default_memory_mb: 512,
        default_storage_gb: 10,
        app_id: app.id
      })

    allocation = %{
      cpu_cores: version.default_cpu_cores,
      memory_mb: version.default_memory_mb,
      storage_gb: version.default_storage_gb
    }

    pricing = PricingSnapshot.snapshot(allocation, version, DateTime.utc_now())

    assert pricing.size_id == nil
    assert pricing.monthly_cents == nil
    assert pricing.stopped_monthly_cents == nil
    assert pricing.grandfathered_until == nil
  end

  test "the clock is now + 1 year, from the passed now" do
    version = InstanceFixtures.app_version!()

    allocation = %{
      cpu_cores: version.default_cpu_cores,
      memory_mb: version.default_memory_mb,
      storage_gb: version.default_storage_gb
    }

    # A fixed past instant pins the arithmetic exactly.
    now = DateTime.add(DateTime.utc_now(), -3_600)

    pricing = PricingSnapshot.snapshot(allocation, version, now)

    assert DateTime.compare(pricing.grandfathered_until, DateTime.shift(now, year: 1)) == :eq
  end
end
