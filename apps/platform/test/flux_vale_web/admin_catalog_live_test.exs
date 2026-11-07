defmodule FluxValeWeb.AdminCatalogLiveTest do
  @moduledoc false

  # The catalog surgery list (#501): one grouped table, every version
  # showing its allocation, the price it rides via its size, and its
  # first-run contract presence. Reads are the public catalog reads
  # under the admin actor; the route gates here are the shared
  # live_session's (:admin_auth pipeline — the anonymous 302 and the
  # non-admin 403), one pin on this surface.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.PricingFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    admin =
      User.create!(
        "admin-catalog-admin-#{@n}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin), bare_conn: conn}
  end

  describe "the surgery list" do
    # Everything in a ConnCase test rolls back (the sandbox), so the
    # empty catalog arm is deterministic whenever this test runs.
    test "an empty catalog renders the empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/catalog")

      assert has_element?(view, "[data-testid='admin-catalog']")
      assert has_element?(view, "[data-testid='admin-catalog-list'] p", "No apps")
    end

    test "lists apps with versions, allocations, prices, and first-run presence", %{
      conn: conn
    } do
      contracted =
        InstanceFixtures.app_version!(%{
          first_run: %{
            pattern: "first_open_sets_password",
            env: %{"POSTGRES_PASSWORD" => "secret"},
            forbidden_env: ["registration_enabled"],
            guidance: "Set the password on first open."
          }
        })

      bare = InstanceFixtures.app_version!()
      app = Ash.load!(bare, [:app, :recommended_size]).app

      {:ok, view, _html} = live(conn, "/admin/catalog")

      # One grouped table: the app rides its own column, keyed by slug.
      assert has_element?(view, "[data-testid='admin-app-cell-#{app.slug}']")
      assert has_element?(view, "[data-testid='admin-app-cell-#{app.slug}']", app.name)

      # The allocation is the version's own blueprint defaults, in the
      # product's middle-dot shape.
      assert has_element?(
               view,
               "[data-testid='admin-version-allocation-#{bare.id}']",
               "0.5 CPU · 256 MB · 0 GB"
             )

      # The price is the recommended size's monthly rate, in the
      # product's one-string idiom.
      priced = Ash.load!(bare, [:recommended_size])
      rate = "#{FluxVale.Pricing.format_usd(priced.recommended_size.monthly_cents)}/mo"

      assert has_element?(view, "[data-testid='admin-version-price-#{bare.id}']", rate)

      # First-run presence: one contracted, one not.
      assert has_element?(view, "[data-testid='admin-version-firstrun-#{contracted.id}']")
      assert has_element?(view, "[data-testid='admin-version-firstrun-#{bare.id}']")

      # Every version hands off to its edit form.
      assert has_element?(
               view,
               "[data-testid='admin-version-edit-#{bare.id}'][href='/admin/catalog/versions/#{bare.id}']"
             )

      # The size ladder is one hop away.
      assert has_element?(
               view,
               "[data-testid='admin-sizes-link'][href='/admin/catalog/sizes']"
             )
    end

    # The rows follow the app page's own :list_for_app order — the
    # version string descending, string-sort (so "1.0.9" sorts above
    # "1.0.10", exactly as the public detail page renders them). Pinned
    # with the pair that kills any accidental numeric or
    # insertion-order sort.
    test "a version's siblings follow the catalog's own string-desc order", %{conn: conn} do
      v9 = InstanceFixtures.app_version!(%{version: "1.0.9"})

      matching_size =
        PricingFixtures.size!(%{
          slug: "sort-mate-#{@n}",
          cpu_cores: Decimal.new("0.5"),
          memory_mb: 256,
          storage_gb: 0
        })

      _v10 =
        AppVersion.create!(
          %{
            version: "1.0.10",
            image: "registry.example.com/app:1.0.10",
            port: 3000,
            default_cpu_cores: Decimal.new("0.5"),
            default_memory_mb: 256,
            default_storage_gb: 0,
            app_id: v9.app_id,
            recommended_size_id: matching_size.id
          },
          authorize?: false
        )

      {:ok, view, _html} = live(conn, "/admin/catalog")

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.query(document, "[data-testid^='admin-version-name-']")

      names =
        for match <- Enum.to_list(matches) do
          text = LazyHTML.text(match)
          String.trim(text)
        end

      assert names == ["1.0.9", "1.0.10"]
    end

    test "a version no action can produce (nil size, the pre-#125 drift shape) reads honestly", %{
      conn: conn
    } do
      version = InstanceFixtures.app_version!()

      # Ash.Seed.seed!, not an action: a sizeless version is the
      # pre-#125 drift shape — every action path requires a recommended
      # size, so only a seed can produce this row (the list must not
      # lie about it).
      sizeless =
        Ash.Seed.seed!(AppVersion, %{
          version: "0.0.#{rem(@n, 100)}",
          image: "registry.example.com/app:0.0",
          port: 3000,
          app_id: version.app_id
        })

      {:ok, view, _html} = live(conn, "/admin/catalog")

      assert has_element?(view, "[data-testid='admin-version-price-#{sizeless.id}']", "No size")
    end
  end

  describe "route gates (the shared live_session's arms)" do
    test "anonymous bounces to /sign-in", %{bare_conn: conn} do
      conn = get(conn, "/admin/catalog")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "a signed-in non-admin gets a bare 403", %{bare_conn: conn} do
      user = SessionHelpers.user!()
      signed = SessionHelpers.sign_in(conn, user)
      conn = get(signed, "/admin/catalog")

      assert conn.status == 403
    end
  end
end
