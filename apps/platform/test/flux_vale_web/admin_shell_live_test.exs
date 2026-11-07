defmodule FluxValeWeb.AdminShellLiveTest do
  @moduledoc false

  # The admin section sidebar in place (ADR-0027 Am. 4, #501): the
  # shell renders on every live section surface, the active entry
  # follows the route (catalog's sub-routes mark the catalog entry),
  # /admin bounces to the first live section, and the gate arms
  # survive the new shape. Replaces the retired homepage-cards suite
  # (the surface map, its testids, and its coverage died with it).

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @n :erlang.unique_integer([:positive])

  @live_surfaces [
    {"people", "/admin/people"},
    {"catalog", "/admin/catalog"},
    {"sizes ladder", "/admin/catalog/sizes"}
  ]

  setup %{conn: conn} do
    admin =
      User.create!(
        "admin-shell-admin-#{@n}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    built = InstanceFixtures.app_version!()
    version = Ash.load!(built, [:app, :recommended_size])

    %{
      admin: admin,
      version: version,
      conn: SessionHelpers.sign_in(conn, admin)
    }
  end

  describe "the shell on every live section surface" do
    test "the sidebar renders beside the people, catalog, and sizes surfaces", %{
      conn: conn
    } do
      for {_section, path} <- @live_surfaces do
        {:ok, view, _html} = live(conn, path)
        assert has_element?(view, "[data-testid='admin-sidebar']")
      end
    end

    test "the edit forms are catalog sub-routes — the shell rides them too", %{
      conn: conn,
      version: version
    } do
      {:ok, size_edit, _html} = live(conn, "/admin/catalog/sizes/#{version.recommended_size.id}")
      assert has_element?(size_edit, "[data-testid='admin-sidebar']")

      {:ok, version_edit, _html} = live(conn, "/admin/catalog/versions/#{version.id}")
      assert has_element?(version_edit, "[data-testid='admin-sidebar']")
    end
  end

  describe "active state per section and sub-route" do
    test "the people surface marks the people entry and nothing else", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/people")

      current = render(element(view, "[data-testid='admin-nav-people']"))
      assert current =~ ~s(aria-current="page")

      quiet = render(element(view, "[data-testid='admin-nav-catalog']"))
      refute quiet =~ "aria-current", "catalog should stay quiet on the people surface"
    end

    test "the catalog surface and every catalog sub-route mark the catalog entry", %{
      conn: conn,
      version: version
    } do
      paths = [
        "/admin/catalog",
        "/admin/catalog/sizes",
        "/admin/catalog/sizes/#{version.recommended_size.id}",
        "/admin/catalog/versions/#{version.id}"
      ]

      for path <- paths do
        {:ok, view, _html} = live(conn, path)

        current = render(element(view, "[data-testid='admin-nav-catalog']"))
        assert current =~ ~s(aria-current="page"), "#{path} should mark the catalog entry"

        quiet = render(element(view, "[data-testid='admin-nav-people']"))
        refute quiet =~ "aria-current", "people should stay quiet on #{path}"
      end
    end
  end

  describe "the homepage is gone" do
    test "/admin bounces to the first live section", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/people"}}} = live(conn, "/admin")

      # The destination is the people surface, in the shell.
      {:ok, view, _html} = live(conn, "/admin/people")
      assert has_element?(view, "[data-testid='admin-people']")
      assert has_element?(view, "[data-testid='admin-sidebar']")
    end

    test "the console-level back link is gone — the sidebar owns wayfinding", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/people")

      refute has_element?(view, "[data-testid='admin-people-back-link']")
    end

    test "the old surface-map testids are gone with the cards", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/people")

      for key <- ["people", "catalog", "wallets", "feedback", "orgs", "gateways"] do
        refute has_element?(view, "[data-testid='admin-surface-#{key}']")
      end
    end
  end

  describe "the coming entries stay dead" do
    test "badged, linkless, on a live surface", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/people")

      for key <- ["wallets", "feedback", "orgs", "gateways"] do
        assert has_element?(view, "[data-testid='admin-coming-#{key}']", "Coming")
        refute has_element?(view, "[data-testid='admin-nav-#{key}'][href]")
      end
    end
  end

  describe "the gate arms through the new shell" do
    # The arms below ride a session-less conn — the setup conn is
    # already signed in as the admin, and these arms exercise the gate
    # exactly when the session (or its absence) decides.
    test "anonymous bounces to /sign-in (route-level gate)", %{conn: _conn} do
      conn = get(build_conn(), "/admin")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "a signed-in non-admin gets a bare 403 (route-level gate)", %{conn: conn} do
      user = User.create!("admin-shell-user-#{@n}@fluxvale.com", %{}, authorize?: false)

      conn =
        conn
        |> SessionHelpers.sign_in(user)
        |> get("/admin")

      assert conn.status == 403
    end

    test "a bearer-only socket bounces at mount on a section surface (AdminGate)", %{
      admin: admin
    } do
      # The PAT is minted for the ADMIN (self-mint, ApiPat's gate), so
      # the route pipeline passes on the bearer — and the socket still
      # carries no session, which is what AdminGate re-checks.
      pat = ApiPat.mint!(admin.email, ["instances:read"])
      conn = put_req_header(build_conn(), "authorization", "Bearer " <> pat)

      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/admin/people")
    end
  end
end
