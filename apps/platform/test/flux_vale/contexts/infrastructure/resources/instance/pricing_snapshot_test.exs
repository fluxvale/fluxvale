defmodule FluxVale.Infrastructure.Instance.PricingSnapshotTest do
  @moduledoc """
  The one pricing-snapshot choice (#121/#186), extracted per #493 so
  the resize prices identically to create: at the recommendation the
  recommended Size row snapshots, any dimension off prices by the
  anchor formula, a sizeless recommendation stays unpriced — and the
  clock is always a fresh now + 1 year, except the unpriced arm's nil.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Infrastructure.Instance.PricingSnapshot
  alias FluxVale.Pricing
  alias FluxVale.TestSupport.InstanceFixtures

  test "at the recommendation: the size row's cents + size_id" do
    version = InstanceFixtures.app_version!(monthly_cents: 335, stopped_monthly_cents: 40)
    size = Ash.load!(version, :recommended_size, authorize?: false).recommended_size

    allocation = %{
      cpu_cores: version.default_cpu_cores,
      memory_mb: version.default_memory_mb,
      storage_gb: version.default_storage_gb
    }

    pricing = PricingSnapshot.snapshot(allocation, version, DateTime.utc_now())

    assert pricing.size_id == size.id
    assert pricing.monthly_cents == 335
    assert pricing.stopped_monthly_cents == 40
    assert pricing.grandfathered_until
  end

  test "a custom allocation: formula cents, nil size" do
    version = InstanceFixtures.app_version!(monthly_cents: 335, stopped_monthly_cents: 40)

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
