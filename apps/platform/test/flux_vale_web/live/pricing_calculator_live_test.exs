defmodule FluxValeWeb.PricingCalculatorLiveTest do
  @moduledoc false

  # The /pricing calculator (#440): embedded by the controller page, so
  # the embed's SSR is asserted in pricing_controller_test. This file
  # drives the child LiveView itself — live_isolated, because /pricing
  # routes to a controller, not a live route (live/2 needs one).

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Pricing
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.PricingFixtures
  alias FluxValeWeb.AllocationSliders

  # The seeded six (micro..pro): the sliders' ladders and the mount's
  # internal presets. Tests that need app-chooser fixtures create them
  # AFTER this, so the seed's guarded delete never runs while a fixture
  # size is referenced.
  setup tags do
    unless tags[:no_seed] do
      :ok = FluxVale.Seeds.seed_pricing!()
    end

    %{}
  end

  # --- Default state ----------------------------------------------------------

  test "opens at the small rungs with the curve-priced total and the stopped line", %{
    conn: conn
  } do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    # The live total announces its updates (the top-up wizard's
    # aria-live pattern).
    assert has_element?(view, "[data-testid='calculator-price'] [aria-live='polite']")

    assert_total(view, small_allocation())
    assert has_element?(view, "[data-testid='calculator-allocation']", "0.5 CPU · 512 MB · 10 GB")
  end

  test "the sliders sit at the small rung indices at mount", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    # The thumbs carry their rung's index: small is 0.5 cores, 512 MB,
    # 10 GB — indices 1, 0, 1 on the ladders.
    assert has_element?(view, "#resource-cpu-cores[value='1']")
    assert has_element?(view, "#resource-memory-mb[value='0']")
    assert has_element?(view, "#resource-storage-gb[value='1']")
  end

  # #440: the tiers left the page — no chips, no slugs in the rendered
  # copy. Opaque phx tokens are stripped first (random base64 could
  # carry a slug at an attribute edge by chance).
  test "the size chips are gone and no size name renders", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    refute has_element?(view, "[data-testid^='size-chip-']")

    rendered = strip_opaque_tokens(render(view))

    refute rendered =~ ~r/\b(micro|small|medium|standard|plus|pro)\b/i
    refute rendered =~ "size-chip"
  end

  test "no app is selected at mount and no recommendation line exists", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    assert has_element?(view, "#calculator-app-filter[value='']")
    refute has_element?(view, "[data-testid='calculator-app-recommendation']")
    assert has_element?(view, "[data-testid='calculator-quantity']", "1")
  end

  # --- Slider moves ------------------------------------------------------------

  test "each single-slider move re-prices through price_allocation, merging over the other rungs",
       %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    # CPU alone: index 3 is the "2" rung.
    render_change(view, "resources-change", %{"resources" => %{"cpu_cores" => "3"}})
    cpu = %{cpu_cores: Decimal.new("2"), memory_mb: 512, storage_gb: 10}
    assert_total(view, cpu)

    # Memory alone: index 2 is the "2048" rung.
    render_change(view, "resources-change", %{"resources" => %{"memory_mb" => "2"}})
    memory = %{cpu_cores: Decimal.new("2"), memory_mb: 2048, storage_gb: 10}
    assert_total(view, memory)

    # Storage alone: index 0 is the "5" rung.
    render_change(view, "resources-change", %{"resources" => %{"storage_gb" => "0"}})
    storage = %{cpu_cores: Decimal.new("2"), memory_mb: 2048, storage_gb: 5}
    assert_total(view, storage)
  end

  test "a total after a slider move equals price_allocation plus the enabled service", %{
    conn: conn
  } do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    toggle_services(view, %{"gateway" => "on"})

    render_change(view, "resources-change", %{"resources" => %{"cpu_cores" => "3"}})
    allocation = %{cpu_cores: Decimal.new("2"), memory_mb: 512, storage_gb: 10}

    assert_total(view, allocation, AccessGateway.monthly_cents())
  end

  # --- Seeded allocations ---------------------------------------------------------

  test "the total equals price_allocation at every seeded allocation, driven by the sliders", %{
    conn: conn
  } do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    for size <- seeded_sizes!() do
      move_rungs(view, size)

      allocation = %{
        cpu_cores: size.cpu_cores,
        memory_mb: size.memory_mb,
        storage_gb: size.storage_gb
      }

      assert_total(view, allocation)
    end
  end

  # --- App chooser ----------------------------------------------------------------

  test "a representable recommendation snaps the sliders, re-prices, and names the app", %{
    conn: conn
  } do
    # The fixture's recommended size is its defaults: 0.5 cores, 2048 MB,
    # 20 GB — all three on the ladders.
    fixture = InstanceFixtures.app_version!(default_memory_mb: 2048, default_storage_gb: 20)
    version = Ash.load!(fixture, :recommended_size, authorize?: false)
    slug = app_slug!(version)
    app = Ash.load!(version, :app, authorize?: false).app

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)
    pick_app(view, slug)

    # The thumbs carry the recommendation's rung indices.
    assert has_element?(view, "#resource-cpu-cores[value='1']")
    assert has_element?(view, "#resource-memory-mb[value='2']")
    assert has_element?(view, "#resource-storage-gb[value='2']")

    allocation = %{
      cpu_cores: version.recommended_size.cpu_cores,
      memory_mb: version.recommended_size.memory_mb,
      storage_gb: version.recommended_size.storage_gb
    }

    assert_total(view, allocation)

    # The line names the app and the amount, and there is nothing to
    # restore while the sliders already hold it.
    assert has_element?(
             view,
             "[data-testid='calculator-app-recommendation']",
             "#{app.name} recommends this amount of resources"
           )

    assert has_element?(
             view,
             "[data-testid='calculator-recommended-allocation']",
             "0.5 CPU · 2048 MB · 20 GB"
           )

    refute has_element?(view, "#calculator-use-recommended")
  end

  test "a manual edit keeps the line and Use recommended restores the snap", %{conn: conn} do
    fixture = InstanceFixtures.app_version!(default_memory_mb: 2048, default_storage_gb: 20)
    version = Ash.load!(fixture, :recommended_size, authorize?: false)
    slug = app_slug!(version)

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)
    pick_app(view, slug)

    render_change(view, "resources-change", %{"resources" => %{"cpu_cores" => "0"}})

    # Drifted: the line still names the recommendation and offers the way
    # back.
    assert has_element?(view, "[data-testid='calculator-app-recommendation']")
    assert has_element?(view, "#calculator-use-recommended")

    render_click(element(view, "#calculator-use-recommended"))

    assert has_element?(view, "#resource-cpu-cores[value='1']")
    assert has_element?(view, "#resource-memory-mb[value='2']")
    assert has_element?(view, "#resource-storage-gb[value='2']")
    refute has_element?(view, "#calculator-use-recommended")

    allocation = %{
      cpu_cores: version.recommended_size.cpu_cores,
      memory_mb: version.recommended_size.memory_mb,
      storage_gb: version.recommended_size.storage_gb
    }

    assert_total(view, allocation)
  end

  # #440: the nil/off-ladder arm is a no-op — no snap, no line, the
  # select falls back to the prompt so it never disagrees with the rungs.
  test "an off-ladder recommendation is a no-op", %{conn: conn} do
    # 3 cores, 3000 MB, 7 GB: none of the three names a rung.
    version =
      InstanceFixtures.app_version!(
        default_cpu_cores: Decimal.new("3"),
        default_memory_mb: 3000,
        default_storage_gb: 7
      )

    slug = app_slug!(Ash.load!(version, :recommended_size, authorize?: false))

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)
    pick_app(view, slug)

    assert has_element?(view, "#resource-cpu-cores[value='1']")
    assert has_element?(view, "#resource-memory-mb[value='0']")
    assert has_element?(view, "#resource-storage-gb[value='1']")
    assert_total(view, small_allocation())
    refute has_element?(view, "[data-testid='calculator-app-recommendation']")
    assert has_element?(view, "#calculator-app-filter[value='']")
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
    pick_app(view, app.slug)

    # Nothing raises, the rungs stay at small, and the field falls back
    # to empty. There is nothing to snap to and no line to show.
    assert has_element?(view, "#resource-cpu-cores[value='1']")
    assert has_element?(view, "#resource-memory-mb[value='0']")
    assert has_element?(view, "#resource-storage-gb[value='1']")
    assert_total(view, small_allocation())
    refute has_element?(view, "[data-testid='calculator-app-recommendation']")
    assert has_element?(view, "#calculator-app-filter[value='']")
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
    pick_app(view, app.slug)

    assert has_element?(view, "#resource-cpu-cores[value='2']")
    assert has_element?(view, "#resource-memory-mb[value='2']")
    assert has_element?(view, "#resource-storage-gb[value='2']")

    allocation = %{cpu_cores: Decimal.new("1"), memory_mb: 2048, storage_gb: 20}
    assert_total(view, allocation)
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

    refute has_element?(view, "[data-testid='calculator-app-option-#{app.slug}']")
  end

  test "a crafted app slug is silence", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    render_change(view, "pick-app", %{"slug" => "no-such-app"})

    assert_total(view, small_allocation())
    refute has_element?(view, "[data-testid='calculator-app-recommendation']")
  end

  test "a crafted slug payload shape is silence", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    # A non-binary slug (a crafted map) names no clause's shape:
    # silence, the rungs stay put.
    render_change(view, "pick-app", %{"slug" => %{"nested" => "value"}})

    assert_total(view, small_allocation())
    refute has_element?(view, "[data-testid='calculator-app-recommendation']")
  end

  # --- Searchable chooser ---------------------------------------------------------

  test "typing filters the result list by name, case-insensitively", %{conn: conn} do
    first = InstanceFixtures.app_version!(default_memory_mb: 1024, default_storage_gb: 10)
    second = InstanceFixtures.app_version!(default_memory_mb: 2048, default_storage_gb: 20)

    first_slug = app_slug!(Ash.load!(first, :recommended_size, authorize?: false))
    second_slug = app_slug!(Ash.load!(second, :recommended_size, authorize?: false))
    first_name = Ash.load!(first, :app, authorize?: false).app.name

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    filter_apps(view, String.upcase(first_name))

    assert has_element?(view, "[data-testid='calculator-app-option-#{first_slug}']", first_name)
    refute has_element?(view, "[data-testid='calculator-app-option-#{second_slug}']")
  end

  test "a filter with no match renders the no-results state", %{conn: conn} do
    InstanceFixtures.app_version!()

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    filter_apps(view, "zzz-no-such-app-zzz")

    assert has_element?(view, "[data-testid='calculator-app-no-results']")
    refute has_element?(view, "[data-testid^='calculator-app-option-']")
  end

  test "each result row carries the app logo with an initial fallback", %{conn: conn} do
    icon = "https://example.com/icons/tools.svg"
    fixture = InstanceFixtures.app_version!(icon_url: icon, default_memory_mb: 2048)
    slug = app_slug!(Ash.load!(fixture, :recommended_size, authorize?: false))

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    assert has_element?(
             view,
             "[data-testid='calculator-app-option-#{slug}'] img[src='#{icon}']"
           )
  end

  test "the chooser is keyboard reachable: a labelled search field and real buttons", %{
    conn: conn
  } do
    fixture = InstanceFixtures.app_version!(default_memory_mb: 2048)
    slug = app_slug!(Ash.load!(fixture, :recommended_size, authorize?: false))

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    assert has_element?(view, "#calculator-app-filter[aria-labelledby='calculator-apps-label']")
    assert has_element?(view, "button[data-testid='calculator-app-option-#{slug}']")
  end

  test "Escape closes the result panel and typing reopens it", %{conn: conn} do
    fixture = InstanceFixtures.app_version!(default_memory_mb: 2048)
    slug = app_slug!(Ash.load!(fixture, :recommended_size, authorize?: false))

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    assert has_element?(view, "[data-testid='calculator-app-option-#{slug}']")

    render_keydown(element(view, "#calculator-app-filter"), %{"key" => "Escape"})
    refute has_element?(view, "[data-testid='calculator-app-option-#{slug}']")

    filter_apps(view, "")
    assert has_element?(view, "[data-testid='calculator-app-option-#{slug}']")
  end

  test "focusing the field reopens the panel after a pick, marking the choice", %{conn: conn} do
    fixture = InstanceFixtures.app_version!(default_memory_mb: 2048, default_storage_gb: 20)
    slug = app_slug!(Ash.load!(fixture, :recommended_size, authorize?: false))

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)
    pick_app(view, slug)

    assert has_element?(view, "[data-testid='calculator-app-recommendation']")

    # The pick closed the panel.
    refute has_element?(view, "[data-testid='calculator-app-option-#{slug}']")

    render_focus(element(view, "#calculator-app-filter"), %{})

    assert has_element?(
             view,
             "button[data-testid='calculator-app-option-#{slug}'][aria-pressed='true']"
           )
  end

  test "the filter also matches the slug", %{conn: conn} do
    fixture = InstanceFixtures.app_version!(app_slug: "needle-app", default_memory_mb: 2048)
    slug = app_slug!(Ash.load!(fixture, :recommended_size, authorize?: false))

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    filter_apps(view, "needle")

    assert has_element?(view, "[data-testid='calculator-app-option-#{slug}']")
  end

  test "a non-string filter payload is silence", %{conn: conn} do
    fixture = InstanceFixtures.app_version!(default_memory_mb: 2048)
    slug = app_slug!(Ash.load!(fixture, :recommended_size, authorize?: false))

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    render_change(view, "filter-apps", %{"app_filter" => %{"nested" => "value"}})

    assert has_element?(view, "[data-testid='calculator-app-option-#{slug}']")
  end

  test "submitting the filter form keeps the state and never navigates", %{conn: conn} do
    fixture = InstanceFixtures.app_version!(default_memory_mb: 2048, default_storage_gb: 20)
    slug = app_slug!(Ash.load!(fixture, :recommended_size, authorize?: false))

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)
    pick_app(view, slug)

    app_form = form(view, "#calculator-app-form", %{"app_filter" => slug})
    render_submit(app_form)

    # The submit is a server event, not a browser navigation. The app
    # stays picked and the filter text lands.
    assert has_element?(view, "[data-testid='calculator-app-recommendation']")
    assert has_element?(view, "[data-testid='calculator-app-option-#{slug}']")
    assert has_element?(view, "#calculator-app-filter[value='#{slug}']")
  end

  test "a crafted Use recommended click with no recommendation is silence", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    render_click(view, "use-recommended", %{})

    assert_total(view, small_allocation())
    refute has_element?(view, "[data-testid='calculator-app-recommendation']")
  end

  test "the explicit Clear empties the filter, drops the line, and keeps the rungs", %{
    conn: conn
  } do
    fixture = InstanceFixtures.app_version!(default_memory_mb: 2048, default_storage_gb: 20)
    slug = app_slug!(Ash.load!(fixture, :recommended_size, authorize?: false))

    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)
    pick_app(view, slug)
    filter_apps(view, "leftover")

    clear = element(view, "#calculator-app-clear")
    render_click(clear)

    refute has_element?(view, "[data-testid='calculator-app-recommendation']")
    assert has_element?(view, "#calculator-app-filter[value='']")
    assert has_element?(view, "#resource-memory-mb[value='2']")
    allocation = %{cpu_cores: Decimal.new("0.5"), memory_mb: 2048, storage_gb: 20}
    assert_total(view, allocation)
  end

  # --- Service toggles ---------------------------------------------------------

  # The marker is template-borne — the toggle helper injects
  # services[_marker] itself — so without this pin, deleting the input
  # would keep every test green while an all-off untoggle froze a stale
  # total.
  test "the hidden marker input rides the services form", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    assert has_element?(view, "input[name='services[_marker]']")
  end

  test "the gateway toggle adds its exact accessor cents and untoggling removes them", %{
    conn: conn
  } do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    assert_total(view, small_allocation())

    toggle_services(view, %{"gateway" => "on"})
    assert_total(view, small_allocation(), AccessGateway.monthly_cents())

    toggle_services(view, %{})
    assert_total(view, small_allocation())
  end

  test "the domain toggle is free and adds nothing to either figure", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    assert has_element?(view, "[data-testid='service-toggle-domain']", "Free")

    toggle_services(view, %{"domain" => "on"})
    assert_total(view, small_allocation())
  end

  test "only the gateway contributes when both toggles are on", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    toggle_services(view, %{"gateway" => "on", "domain" => "on"})

    assert_total(view, small_allocation(), AccessGateway.monthly_cents())
  end

  test "the gateway explainer states what it is, how it bills, and where to set it up", %{
    conn: conn
  } do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    assert has_element?(
             view,
             "[data-testid='gateway-explainer']",
             "Private access to your apps without public exposure."
           )

    assert has_element?(
             view,
             "[data-testid='gateway-explainer']",
             "bills once, hourly"
           )

    assert has_element?(
             view,
             "[data-testid='gateway-explainer']",
             "Set it up in Settings → Access."
           )
  end

  test "a service sent an explicit off value reads as off", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    toggle_services(view, %{"gateway" => "on"})
    assert_total(view, small_allocation(), AccessGateway.monthly_cents())

    toggle_services(view, %{"gateway" => "off"})
    assert_total(view, small_allocation())
  end

  test "a non-map services payload is silence", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    toggle_services(view, %{"gateway" => "on"})

    render_change(view, "services-change", %{"services" => "not-a-map"})

    assert_total(view, small_allocation(), AccessGateway.monthly_cents())
  end

  # --- Quantity ------------------------------------------------------------------

  test "the quantity multiplies the curve and bills services once", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)
    toggle_services(view, %{"gateway" => "on"})

    render_click(view, "quantity-change", %{"delta" => "1"})
    render_click(view, "quantity-change", %{"delta" => "1"})

    assert has_element?(view, "[data-testid='calculator-quantity']", "3")

    # Three instances at the same allocation, the gateway once.
    assert_fleet_total(view, small_allocation(), 3, AccessGateway.monthly_cents())
  end

  test "the allocation line reads per instance and names the count", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    assert has_element?(
             view,
             "[data-testid='calculator-allocation']",
             "0.5 CPU · 512 MB · 10 GB per instance"
           )

    render_click(view, "quantity-change", %{"delta" => "1"})

    assert has_element?(
             view,
             "[data-testid='calculator-allocation']",
             "2 × 0.5 CPU · 512 MB · 10 GB per instance"
           )
  end

  test "the quantity clamps at one and at the ceiling", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    render_click(view, "quantity-change", %{"delta" => "-1"})
    assert has_element?(view, "[data-testid='calculator-quantity']", "1")

    for _count <- 1..25 do
      render_click(view, "quantity-change", %{"delta" => "1"})
    end

    assert has_element?(view, "[data-testid='calculator-quantity']", "20")
    assert has_element?(view, "#calculator-quantity-increase[disabled]")
  end

  test "a crafted quantity delta is silence", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    render_click(view, "quantity-change", %{"delta" => "100"})

    assert has_element?(view, "[data-testid='calculator-quantity']", "1")
    assert_total(view, small_allocation())
  end

  # --- Crafted slider payloads -------------------------------------------------

  test "a non-map resources payload is silence", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    render_change(view, "resources-change", %{"resources" => "not-a-map"})

    assert_total(view, small_allocation())
    assert has_element?(view, "#resource-cpu-cores[value='1']")
  end

  test "a crafted rung index that names no rung is dropped", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    render_change(view, "resources-change", %{"resources" => %{"cpu_cores" => "99"}})

    assert_total(view, small_allocation())
    assert has_element?(view, "#resource-cpu-cores[value='1']")
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

    assert_total(view, allocation)
    assert has_element?(view, "#resource-cpu-cores[value='2']")
  end

  @tag no_seed: true
  test "with no size rows at all the rungs floor to the ladders' bottoms", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, FluxValeWeb.PricingCalculatorLive)

    allocation = %{cpu_cores: Decimal.new("0.25"), memory_mb: 512, storage_gb: 5}

    assert_total(view, allocation)
    assert has_element?(view, "#resource-cpu-cores[value='0']")
    assert has_element?(view, "#resource-memory-mb[value='0']")
    assert has_element?(view, "#resource-storage-gb[value='0']")
  end

  # --- Helpers ----------------------------------------------------------------

  defp small_allocation do
    %{cpu_cores: Decimal.new("0.5"), memory_mb: 512, storage_gb: 10}
  end

  # Both figures are one instance's curve at the rungs plus the enabled
  # services' exact cents (they bill once, whatever the quantity). The
  # gateway settles regardless of instance state, so the stopped line
  # owes it too.
  defp assert_total(view, allocation, service_cents \\ 0) do
    assert_fleet_total(view, allocation, 1, service_cents)
  end

  defp assert_fleet_total(view, allocation, quantity, service_cents) do
    priced = Pricing.price_allocation(allocation)

    assert has_element?(
             view,
             "[data-testid='calculator-total']",
             Pricing.format_monthly_rate(priced.monthly_cents * quantity + service_cents)
           )

    assert has_element?(
             view,
             "[data-testid='calculator-price-stopped']",
             stopped_label(allocation, quantity, service_cents)
           )
  end

  defp stopped_label(allocation, quantity, service_cents) do
    stopped = Pricing.price_allocation(allocation).stopped_monthly_cents * quantity
    Pricing.format_usd(stopped + service_cents) <> "/mo while stopped"
  end

  # The chooser's result button, clicked the way a visitor activates it
  # (keyboard Enter and a pointer click both land here).
  defp pick_app(view, slug) do
    view
    |> element("[data-testid='calculator-app-option-#{slug}']")
    |> render_click()
  end

  # Typing in the search field: the form's change event carries the
  # input value.
  defp filter_apps(view, text) do
    render_change(view, "filter-apps", %{"app_filter" => text})
  end

  # The toggles' change, driven directly with the payload the browser
  # serializes: the always-present marker plus a key per checked box.
  # (The form helper's validator knows checkboxes only as on, so an
  # absent or off key can't ride through it.)
  defp toggle_services(view, checked) do
    services = Map.merge(%{"_marker" => "1"}, checked)
    render_change(view, "services-change", %{"services" => services})
  end

  # The view's own read, mirrored: the presets' source list.
  defp seeded_sizes! do
    FluxVale.Pricing.Size
    |> Ash.Query.for_read(:read, %{}, actor: nil)
    |> Ash.Query.sort(:monthly_cents)
    |> Ash.read!()
  end

  # Drives the sliders to a size's rungs: each dimension's rung value is
  # translated to its ladder index, the way a thumb move arrives.
  defp move_rungs(view, size) do
    rungs =
      Map.new(
        %{
          "cpu_cores" => rung_index("cpu_cores", size.cpu_cores),
          "memory_mb" => rung_index("memory_mb", size.memory_mb),
          "storage_gb" => rung_index("storage_gb", size.storage_gb)
        },
        fn {key, index} -> {key, Integer.to_string(index)} end
      )

    render_change(view, "resources-change", %{"resources" => rungs})
  end

  defp rung_index(dimension_key, value) do
    values = dimension(dimension_key).values

    needle =
      case value do
        %Decimal{} = decimal -> decimal_string(decimal)
        integer when is_integer(integer) -> Integer.to_string(integer)
      end

    Enum.find_index(values, &(&1 == needle))
  end

  defp dimension(dimension_key) do
    dimensions = AllocationSliders.resource_dimensions()
    Enum.find(dimensions, fn dimension -> dimension.key == dimension_key end)
  end

  defp decimal_string(value) do
    value
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  # The fixture builds its own app; the version row is the handle to it.
  defp app_slug!(version) do
    Ash.load!(version, :app, authorize?: false).app.slug
  end

  defp strip_opaque_tokens(html) do
    # Class attributes are styling tokens, never copy (icon sizing alone
    # carries "-micro" fragments); the phx/CSRF values are random base64.
    # None of those are rendered text, and all can false-positive the
    # slug check, so only the markup's text survives them.
    without_view_tokens = Regex.replace(~r/data-phx-(session|static)="[^"]*"/, html, "")
    without_csrf = Regex.replace(~r/name="csrf-token" content="[^"]*"/, without_view_tokens, "")
    Regex.replace(~r/class="[^"]*"/, without_csrf, "")
  end
end
