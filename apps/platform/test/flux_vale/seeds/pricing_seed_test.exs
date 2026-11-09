defmodule FluxVale.Seeds.PricingSeedTest do
  @moduledoc """
  The pricing seed flow (`FluxVale.Seeds.seed_pricing!/1`) against a
  sandboxed DB — create, reprice-convergence, and idempotency (#125).
  """

  # Sync: a seed writes shared rows, so it must not overlap another test.

  use FluxVale.DataCase, async: false

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Pricing.Size
  alias FluxVale.Seeds
  alias FluxVale.TestSupport.InstanceFixtures

  describe "seed_pricing!/0 (shipped data)" do
    test "seeds the six compute classes cleanly (#558)" do
      assert :ok == Seeds.seed_pricing!()

      small = Size.get_by_slug!("small", authorize?: false)

      assert Decimal.equal?(small.cpu_cores, Decimal.new("0.5"))
      assert small.memory_mb == 512
      assert small.monthly_cents == 295
    end

    test "re-seeding converges drifted prices back to the YAML" do
      assert :ok == Seeds.seed_pricing!()

      small = Size.get_by_slug!("small", authorize?: false)
      Size.update!(small, %{monthly_cents: 999}, authorize?: false)

      assert :ok == Seeds.seed_pricing!()

      assert Size.get_by_slug!("small", authorize?: false).monthly_cents == 295
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
          monthly_cents: 259
        }
      ]

      assert :ok == Seeds.seed_pricing!(entries)

      assert Size.get_by_slug!(hd(entries).slug, authorize?: false).monthly_cents == 259
    end
  end

  describe "the guarded delete (#399)" do
    test "a DB that has an ultra row converges to one without it" do
      # The pre-trim row, left behind by an environment seeded before
      # #399. Sizes are admin business data, so the precondition rides
      # the create action like any other size.
      ultra_row!()

      assert :ok == Seeds.seed_pricing!()

      assert {:error, _not_found} = Size.get_by_slug("ultra", authorize?: false)
      assert length(Ash.read!(Size, authorize?: false)) == 6
    end

    test "the delete refuses while an instance still references the row" do
      ultra = ultra_row!()
      version = InstanceFixtures.app_version!()

      # size_id rides DeriveFromAppVersion only — no action accepts it,
      # and aiming the derive at this exact row would drag the whole
      # actor/org deploy funnel into a seed precondition. Ash.seed! is
      # the sanctioned escape (same posture as the org-instance helper
      # in test/flux_vale_web/live/org_live/home_test.exs).
      Ash.Seed.seed!(Instance, %{
        name: "On the removed size",
        slug: "inst-#{System.unique_integer([:positive])}",
        image: "registry.example.com/app:1.0",
        port: 3000,
        healthcheck_path: "/",
        status: :running,
        env_vars: %{},
        app_version_id: version.id,
        size_id: ultra.id
      })

      assert_raise RuntimeError,
                   ~r/still referenced.*instance .* references size "ultra"/s,
                   fn -> Seeds.seed_pricing!() end

      # Nothing was destroyed: the guard fires before any delete.
      assert Size.get_by_slug!("ultra", authorize?: false)
    end

    test "the delete refuses while a version still recommends the row" do
      ultra = ultra_row!()

      n = System.unique_integer()

      category =
        Category.create!(
          %{name: "Tools #{n}", slug: "tools-#{n}", description: "test category"},
          authorize?: false
        )

      app =
        App.create!(
          %{
            name: "App #{n}",
            slug: "app-#{n}",
            tagline: "test app",
            description: "test app",
            category_id: category.id
          },
          authorize?: false
        )

      # Through the action: ValidateSizeMatchesAllocation requires the
      # version's compute defaults to equal the recommended size's
      # compute (#558), so they mirror the removed row's.
      AppVersion.create!(
        %{
          version: "1.0.0",
          image: "registry.example.com/app:1.0",
          port: 3000,
          default_cpu_cores: ultra.cpu_cores,
          default_memory_mb: ultra.memory_mb,
          app_id: app.id,
          recommended_size_id: ultra.id
        },
        authorize?: false
      )

      assert_raise RuntimeError,
                   ~r/still referenced.*app version 1.0.0 .* recommends size "ultra"/s,
                   fn -> Seeds.seed_pricing!() end

      assert Size.get_by_slug!("ultra", authorize?: false)
    end
  end

  # The #399 trim's removed row, in its pre-trim compute shape (the
  # storage-era fields died with #558) — what an environment seeded
  # before the trim carries. Get-or-create: a committed row from
  # another lane must not collide the unique slug.
  defp ultra_row! do
    attrs = %{
      slug: "ultra",
      cpu_cores: Decimal.new("6"),
      memory_mb: 12_288,
      monthly_cents: 2216
    }

    case Size.get_by_slug(attrs.slug, authorize?: false) do
      {:ok, size} -> size
      {:error, _not_found} -> Size.create!(attrs, authorize?: false)
    end
  end
end
