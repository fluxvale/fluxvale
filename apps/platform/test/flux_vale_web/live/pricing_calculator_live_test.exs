defmodule FluxValeWeb.PricingCalculatorLiveTest do
  @moduledoc false

  # The /pricing calculator (#397): embedded by the controller page, so
  # the embed's SSR is asserted in pricing_controller_test. This file
  # drives the child LiveView itself — live_isolated, because /pricing
  # routes to a controller, not a live route (live/2 needs one).

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Pricing
  alias FluxVale.Pricing.Size
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.PricingFixtures

  # The seeded six (micro..pro): the chips' source. Tests that need the
  # app chooser fixtures create them AFTER this, so the seed's guarded
  # delete never runs while a fixture size is referenced.
  setup tags do
    unless tags[:no_seed] do
      :ok = FluxVale.Seeds.seed_pricing!()
    end

    %{}
  end

  # --- Default state ----------------------------------------------------------

  test "opens at the small rungs with the price_allocation price", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    allocation = small_allocation()

    # The live figures announce their updates (the top-up wizard's
    # aria-live pattern).
    assert has_element?(
             view,
             "[data-testid='calculator-price'] span[aria-live='polite']"
           )

    assert has_element?(
             view,
             "[data-testid='calculator-price-running']",
             Pricing.format_monthly_rate(Pricing.price_allocation(allocation).monthly_cents)
           )

    assert has_element?(
             view,
             "[data-testid='calculator-price-stopped']",
             stopped_label(allocation)
           )

    assert has_element?(view, "[data-testid='calculator-allocation']", "0.5 CPU · 512 MB · 10 GB")
  end

  test "the small chip is the one pressed at mount, as a string", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    assert has_element?(view, "#size-chip-small[aria-pressed='true']")
    assert has_element?(view, "#size-chip-pro[aria-pressed='false']")
    assert has_element?(view, "#size-chip-micro[aria-pressed='false']")
  end

  test "the sliders sit at the small rung indices at mount", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    # The thumbs carry their rung's index: small is 0.5 cores, 512 MB,
    # 10 GB — indices 1, 0, 1 on the ladders.
    assert has_element?(view, "#resource-cpu-cores[value='1']")
    assert has_element?(view, "#resource-memory-mb[value='0']")
    assert has_element?(view, "#resource-storage-gb[value='1']")
  end

  test "no app is selected and no recommendation line renders at mount", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    refute has_element?(view, "[data-testid='calculator-app-recommendation']")
  end

  # --- Slider moves ------------------------------------------------------------

  test "each single-slider move re-prices through price_allocation, merging over the other rungs",
       %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    # CPU alone: index 3 is the "2" rung.
    render_change(view, "resources-change", %{"resources" => %{"cpu_cores" => "3"}})
    cpu = %{cpu_cores: Decimal.new("2"), memory_mb: 512, storage_gb: 10}
    assert_running_and_stopped(view, cpu)

    # Memory alone: index 2 is the "2048" rung.
    render_change(view, "resources-change", %{"resources" => %{"memory_mb" => "2"}})
    memory = %{cpu_cores: Decimal.new("2"), memory_mb: 2048, storage_gb: 10}
    assert_running_and_stopped(view, memory)

    # Storage alone: index 0 is the "5" rung.
    render_change(view, "resources-change", %{"resources" => %{"storage_gb" => "0"}})
    storage = %{cpu_cores: Decimal.new("2"), memory_mb: 2048, storage_gb: 5}
    assert_running_and_stopped(view, storage)
  end

  # --- Size quick picks ----------------------------------------------------------

  test "every seeded size point prices through price_allocation when picked", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    for size <- seeded_sizes!() do
      pick_chip(view, "size-chip-#{size.slug}")

      allocation = %{
        cpu_cores: size.cpu_cores,
        memory_mb: size.memory_mb,
        storage_gb: size.storage_gb
      }

      assert has_element?(
               view,
               "[data-testid='calculator-price-running']",
               Pricing.format_monthly_rate(Pricing.price_allocation(allocation).monthly_cents)
             )

      assert has_element?(
               view,
               "[data-testid='calculator-price-stopped']",
               stopped_label(allocation)
             )
    end
  end

  test "picking a size moves the pressed state with the allocation", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    pick_chip(view, "size-chip-micro")
    assert has_element?(view, "#size-chip-micro[aria-pressed='true']")
    assert has_element?(view, "#size-chip-small[aria-pressed='false']")

    pick_chip(view, "size-chip-small")
    assert has_element?(view, "#size-chip-small[aria-pressed='true']")
    assert has_element?(view, "#size-chip-micro[aria-pressed='false']")
  end

  test "an off-ladder size gets no chip and its slug is silence", %{conn: conn} do
    # 3 cores, 3000 MB, 7 GB: none of the three names a rung.
    off_ladder =
      PricingFixtures.size!(cpu_cores: Decimal.new("3"), memory_mb: 3000, storage_gb: 7)

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    refute has_element?(view, "[data-testid='size-chip-#{off_ladder.slug}']")

    render_click(view, "pick-size", %{"slug" => off_ladder.slug})

    assert_running_and_stopped(view, small_allocation())
    assert has_element?(view, "#resource-cpu-cores[value='1']")
  end

  test "a crafted size slug is silence", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    render_click(view, "pick-size", %{"slug" => "no-such-size"})

    assert has_element?(view, "#resource-cpu-cores[value='1']")
    assert_running_and_stopped(view, small_allocation())
  end

  # --- App chooser ----------------------------------------------------------------

  test "a representable recommendation snaps the sliders and re-prices", %{conn: conn} do
    # The fixture's recommended size is its defaults: 0.5 cores, 2048 MB,
    # 20 GB — all three on the ladders.
    fixture =
      InstanceFixtures.app_version!(default_memory_mb: 2048, default_storage_gb: 20)

    version = Ash.load!(fixture, :recommended_size, authorize?: false)
    recommended = version.recommended_size

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)
    pick_chip(view, "app-chip-#{app_slug!(version)}")

    # The thumbs carry the recommendation's rung indices.
    assert has_element?(view, "#resource-cpu-cores[value='1']")
    assert has_element?(view, "#resource-memory-mb[value='2']")
    assert has_element?(view, "#resource-storage-gb[value='2']")

    allocation = %{
      cpu_cores: recommended.cpu_cores,
      memory_mb: recommended.memory_mb,
      storage_gb: recommended.storage_gb
    }

    assert_running_and_stopped(view, allocation)

    assert has_element?(
             view,
             "[data-testid='calculator-app-recommendation']",
             "0.5 CPU · 2048 MB · 20 GB"
           )

    assert has_element?(
             view,
             "[data-testid='app-chip-#{app_slug!(version)}'][aria-pressed='true']"
           )
  end

  test "an off-ladder recommendation shows the app's rate as a static line and leaves the rungs alone",
       %{conn: conn} do
    # 3 cores, 3000 MB, 7 GB: none of the three names a rung.
    version =
      InstanceFixtures.app_version!(
        default_cpu_cores: Decimal.new("3"),
        default_memory_mb: 3000,
        default_storage_gb: 7
      )

    loaded = Ash.load!(version, :recommended_size, authorize?: false)
    recommended = loaded.recommended_size
    slug = app_slug!(loaded)

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)
    pick_chip(view, "app-chip-#{slug}")

    expected =
      Pricing.format_monthly_rate(recommended.monthly_cents)

    assert has_element?(
             view,
             "[data-testid='calculator-app-recommendation']",
             "recommends a size these sliders don't cover. That size prices at #{expected}."
           )

    # The sliders and the price stay at the default rungs — the chooser
    # never snapped to a state the sliders can't express.
    assert has_element?(view, "#resource-cpu-cores[value='1']")
    assert has_element?(view, "#resource-memory-mb[value='0']")
    assert has_element?(view, "#resource-storage-gb[value='1']")
    assert_running_and_stopped(view, small_allocation())
    assert has_element?(view, "[data-testid='app-chip-#{slug}'][aria-pressed='true']")
  end

  test "a version with no recommended size is a silent no-op", %{conn: conn} do
    # The fixture's actions always attach a size, and both create and
    # update validate present(:recommended_size_id) — the pre-#125 nil
    # state is only Ash.Seed's to produce (the sanctioned case).
    fixture = InstanceFixtures.app_version!()
    app = Ash.load!(fixture, :app, authorize?: false).app

    Ash.Seed.seed!(AppVersion, %{
      # "9.0.0" sorts above the fixture's "1.0.N" — the nil-size version
      # must be the app's latest, the one whose recommendation the
      # chooser reads.
      version: "9.0.0",
      image: "registry.example.com/app:9.0.0",
      port: 3000,
      default_cpu_cores: Decimal.new("1"),
      default_memory_mb: 1024,
      default_storage_gb: 20,
      app_id: app.id
    })

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)
    pick_chip(view, "app-chip-#{app.slug}")

    # Nothing raises, the rungs stay at small, no line renders, and the
    # chip does not press — there is no rate to show and nothing to
    # snap to.
    assert has_element?(view, "#resource-cpu-cores[value='1']")
    assert has_element?(view, "#resource-memory-mb[value='0']")
    assert has_element?(view, "#resource-storage-gb[value='1']")
    assert_running_and_stopped(view, small_allocation())
    refute has_element?(view, "[data-testid='calculator-app-recommendation']")
    assert has_element?(view, "#app-chip-#{app.slug}[aria-pressed='false']")
  end

  test "the latest version's recommendation is the one that snaps", %{conn: conn} do
    older = InstanceFixtures.app_version!(default_memory_mb: 1024, default_storage_gb: 10)
    app = Ash.load!(older, :app, authorize?: false).app

    # A newer version on the same app, recommending the standard-ish
    # point 1 core, 2048 MB, 20 GB — the size matches its allocation
    # (ValidateSizeMatchesAllocation's contract).
    newer_size =
      PricingFixtures.size!(
        cpu_cores: Decimal.new("1"),
        memory_mb: 2048,
        storage_gb: 20,
        monthly_cents: 621,
        stopped_monthly_cents: 68
      )

    AppVersion.create!(
      %{
        version: "9.0.0",
        image: "registry.example.com/app:9.0.0",
        port: 3000,
        default_cpu_cores: Decimal.new("1"),
        default_memory_mb: 2048,
        default_storage_gb: 20,
        app_id: app.id,
        recommended_size_id: newer_size.id
      },
      authorize?: false
    )

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)
    pick_chip(view, "app-chip-#{app.slug}")

    assert has_element?(view, "#resource-cpu-cores[value='2']")
    assert has_element?(view, "#resource-memory-mb[value='2']")
    assert has_element?(view, "#resource-storage-gb[value='2']")

    allocation = %{cpu_cores: Decimal.new("1"), memory_mb: 2048, storage_gb: 20}
    assert_running_and_stopped(view, allocation)
  end

  test "an app with no version stays off the chooser", %{conn: conn} do
    # An app with zero versions carries no recommendation; built through
    # the create actions (authorize?: false) like the fixtures.
    n = System.unique_integer()

    category =
      Category.create!(
        %{name: "Tools #{n}", slug: "tools-#{n}", description: "test category"},
        authorize?: false
      )

    app =
      App.create!(
        %{
          name: "Versionless #{n}",
          slug: "versionless-#{n}",
          tagline: "test app",
          description: "test app",
          category_id: category.id
        },
        authorize?: false
      )

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    refute has_element?(view, "[data-testid='app-chip-#{app.slug}']")
  end

  test "a crafted app slug is silence", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    render_click(view, "pick-app", %{"slug" => "no-such-app"})

    assert_running_and_stopped(view, small_allocation())
    refute has_element?(view, "[data-testid='calculator-app-recommendation']")
  end

  # --- Crafted slider payloads -------------------------------------------------

  test "a non-map resources payload is silence", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    render_change(view, "resources-change", %{"resources" => "not-a-map"})

    assert_running_and_stopped(view, small_allocation())
    assert has_element?(view, "#resource-cpu-cores[value='1']")
  end

  test "a crafted rung index that names no rung is dropped", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    render_change(view, "resources-change", %{"resources" => %{"cpu_cores" => "99"}})

    assert_running_and_stopped(view, small_allocation())
    assert has_element?(view, "#resource-cpu-cores[value='1']")
  end

  # --- Default fallbacks ----------------------------------------------------------

  @tag no_seed: true
  test "without a small size the cheapest size is the default", %{conn: conn} do
    cheap = PricingFixtures.size!(monthly_cents: 500)
    PricingFixtures.size!(monthly_cents: 900, cpu_cores: Decimal.new("2"), memory_mb: 2048)

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    allocation = %{
      cpu_cores: cheap.cpu_cores,
      memory_mb: cheap.memory_mb,
      storage_gb: cheap.storage_gb
    }

    assert_running_and_stopped(view, allocation)
    assert has_element?(view, "#size-chip-#{cheap.slug}[aria-pressed='true']")
  end

  @tag no_seed: true
  test "with no size rows at all the rungs floor to the ladders' bottoms", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    allocation = %{cpu_cores: Decimal.new("0.25"), memory_mb: 512, storage_gb: 5}

    assert_running_and_stopped(view, allocation)
    assert has_element?(view, "#resource-cpu-cores[value='0']")
    assert has_element?(view, "#resource-memory-mb[value='0']")
    assert has_element?(view, "#resource-storage-gb[value='0']")
    refute has_element?(view, "[data-testid^='size-chip-']")
  end

  # --- Copy ---------------------------------------------------------------------

  test "the chooser caption states allocation-only pricing", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    assert has_element?(
             view,
             "[data-testid='pricing-calculator']",
             "The price depends only on the allocation, never the app."
           )
  end

  # --- Helpers ----------------------------------------------------------------

  defp small_allocation do
    %{cpu_cores: Decimal.new("0.5"), memory_mb: 512, storage_gb: 10}
  end

  defp assert_running_and_stopped(view, allocation) do
    priced = Pricing.price_allocation(allocation)

    assert has_element?(
             view,
             "[data-testid='calculator-price-running']",
             Pricing.format_monthly_rate(priced.monthly_cents)
           )

    assert has_element?(
             view,
             "[data-testid='calculator-price-stopped']",
             stopped_label(allocation)
           )
  end

  defp stopped_label(allocation) do
    rate = Pricing.format_usd(Pricing.price_allocation(allocation).stopped_monthly_cents)
    rate <> "/mo while stopped"
  end

  # The view's own read, mirrored: the chips' source list.
  defp seeded_sizes! do
    Size
    |> Ash.Query.for_read(:read, %{}, actor: nil)
    |> Ash.Query.sort(:monthly_cents)
    |> Ash.read!()
  end

  # The fixture builds its own app; the version row is the handle to it.
  defp app_slug!(version) do
    Ash.load!(version, :app, authorize?: false).app.slug
  end

  defp pick_chip(view, testid) do
    chip = element(view, "[data-testid='#{testid}']")
    render_click(chip)
  end
end
