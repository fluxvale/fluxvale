defmodule FluxValeWeb.AdminCatalogLiveTest do
  @moduledoc false

  # The catalog surgery list (#501): apps with their versions, each
  # version showing its allocation, the price it rides via its size,
  # and its first-run contract presence. Reads are the public catalog
  # reads under the admin actor; the route gates here are the shared
  # live_session's (:admin_auth pipeline — the anonymous 302 and the
  # non-admin 403), one pin on this surface.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.InstanceFixtures
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
      app = Ash.load!(bare, [:app]).app

      {:ok, view, _html} = live(conn, "/admin/catalog")

      # One card per app, keyed by slug; the version rows ride inside.
      assert has_element?(view, "[data-testid='admin-app-#{app.slug}']")

      # The allocation is the version's own blueprint defaults.
      assert has_element?(
               view,
               "[data-testid='admin-version-allocation-#{bare.id}']",
               "0.5 CPU, 256 MB, 0 GB"
             )

      # The price is the recommended size's monthly rate.
      priced = Ash.load!(bare, [:recommended_size])
      price = FluxVale.Pricing.format_usd(priced.recommended_size.monthly_cents)

      assert has_element?(view, "[data-testid='admin-version-price-#{bare.id}']", price)

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
