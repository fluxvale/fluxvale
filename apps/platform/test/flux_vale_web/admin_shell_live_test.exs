defmodule FluxValeWeb.AdminShellLiveTest do
  @moduledoc false

  # The admin section sidebar in place (ADR-0027 Am. 4, #501): the
  # shell renders on every live section surface, the active entry
  # follows the route (catalog's sub-routes mark the catalog entry),
  # /admin bounces to the first live section, and the gate arms
  # survive the new shape. Replaces the retired homepage-cards suite
  # (the surface map, its testids, and its coverage died with it).

  use FluxValeWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.Billing
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Ops.FeatureFlag
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @n :erlang.unique_integer([:positive])

  @live_surfaces [
    {"people", "/admin/people"},
    {"catalog", "/admin/catalog"},
    {"sizes ladder", "/admin/catalog/sizes"},
    {"wallets", "/admin/billing"},
    {"orgs", "/admin/orgs"},
    {"resources console", "/admin/resources"},
    {"audit", "/admin/audit"}
  ]

  # The console-lane flush test's route source (#593): the router's
  # own :admin enumeration, shared with the shell test below — a new
  # admin route (#571, #592) joins both tests or fails loudly.
  defp admin_live_route_info do
    for r <- FluxValeWeb.Router.__routes__(),
        is_map_key(r, :metadata),
        is_map_key(r.metadata, :phoenix_live_view),
        {_mod, _action, _info, session} = r.metadata.phoenix_live_view,
        session[:name] == :admin,
        r.path != "/admin" do
      {r.path, r.metadata.phoenix_live_view}
    end
  end

  defp concrete_admin_path("/admin/gateways/:id", %{gateway: gateway}),
    do: "/admin/gateways/#{gateway.id}"

  defp concrete_admin_path("/admin/billing/wallets/:id", %{wallet: wallet}),
    do: "/admin/billing/wallets/#{wallet.id}"

  defp concrete_admin_path("/admin/orgs/:id", %{org: org}),
    do: "/admin/orgs/#{org.id}"

  defp concrete_admin_path("/admin/catalog/sizes/:id", %{version: version}),
    do: "/admin/catalog/sizes/#{version.recommended_size.id}"

  defp concrete_admin_path("/admin/catalog/versions/:id", %{version: version}),
    do: "/admin/catalog/versions/#{version.id}"

  defp concrete_admin_path("/admin/resources/:domain", _ctx), do: "/admin/resources/ops"

  defp concrete_admin_path("/admin/resources/:domain/:resource", _ctx),
    do: "/admin/resources/ops/feature_flag"

  defp concrete_admin_path("/admin/resources/:domain/:resource/new", _ctx),
    do: "/admin/resources/ops/feature_flag/new"

  defp concrete_admin_path("/admin/resources/:domain/:resource/:id/edit", %{flag: flag}),
    do: "/admin/resources/ops/feature_flag/#{flag.id}/edit"

  defp concrete_admin_path("/admin/resources/:domain/:resource/:id", %{flag: flag}),
    do: "/admin/resources/ops/feature_flag/#{flag.id}"

  defp concrete_admin_path(literal, _ctx), do: literal

  setup %{conn: conn} do
    # The gateway fixtures' contract (access_fixtures.ex): the
    # provider's cluster leg is Mimic-stubbed — the shell tests care
    # about chrome and navigation, not the Tailscale calls.
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
    stub(Tailscale, :teardown_gateway, fn _gateway -> :ok end)

    admin =
      User.create!(
        "admin-shell-admin-#{@n}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    built = InstanceFixtures.app_version!()
    version = Ash.load!(built, [:app, :recommended_size])

    # The wallets surface's mount target (the enumeration mounts the
    # detail route): a fixture org with its wallet. grant_free_org!
    # returns {org, owner} — the wallet is ensure_wallet's, NOT the
    # second tuple.
    {org, _owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = Billing.ensure_wallet(org)

    # The gateways surface's mount target (the enumeration mounts the
    # detail route): a member org — the members-only reads admit the
    # admin — with its gateway and the provisioned stamp the detail
    # renders (the observer owns the stamp in production, the funnel
    # accepts it: the gateway detail test's own pattern).
    gateway_org_pair = BillingFixtures.grant_free_org!()

    Membership.create!(
      %{organization_id: elem(gateway_org_pair, 0).id, user_id: admin.id, role: :member},
      authorize?: false
    )

    gateway_org = elem(gateway_org_pair, 0)

    gateway =
      gateway_org
      |> AccessFixtures.gateway!()
      |> Ash.Changeset.for_update(
        :update_state,
        %{provisioned_at: DateTime.utc_now()},
        authorize?: false
      )
      |> Ash.update!()

    # The resources console's record path needs one real row (the
    # generic engine's fixture — created through the action, no backdoor).
    flag =
      FeatureFlag
      |> Ash.Changeset.for_create(
        :create,
        %{key: "admin_shell_flag_#{@n}"},
        actor: admin
      )
      |> Ash.create!()

    %{
      admin: admin,
      version: version,
      org: org,
      wallet: wallet,
      gateway: gateway,
      flag: flag,
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
    test "the people surface marks the people entry as the page and nothing else", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/people")

      current = render(element(view, "[data-testid='admin-nav-people']"))
      assert current =~ ~s(aria-current="page")

      quiet = render(element(view, "[data-testid='admin-nav-catalog']"))
      refute quiet =~ "aria-current", "catalog should stay quiet on the people surface"
    end

    test "the catalog surface marks the catalog entry as the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/catalog")

      current = render(element(view, "[data-testid='admin-nav-catalog']"))
      assert current =~ ~s(aria-current="page")
    end

    test "catalog sub-routes mark the catalog entry as an ancestor (location)", %{
      conn: conn,
      version: version
    } do
      # "page" is reserved for the entry whose href IS the mounted
      # page. The ladder and the edit forms are section ancestors.
      paths = [
        "/admin/catalog/sizes",
        "/admin/catalog/sizes/#{version.recommended_size.id}",
        "/admin/catalog/versions/#{version.id}"
      ]

      for path <- paths do
        {:ok, view, _html} = live(conn, path)

        current = render(element(view, "[data-testid='admin-nav-catalog']"))
        assert current =~ ~s(aria-current="location"), "#{path} should mark the section ancestor"
        refute current =~ "page", "#{path} must not claim the page mark"

        quiet = render(element(view, "[data-testid='admin-nav-people']"))
        refute quiet =~ "aria-current", "people should stay quiet on #{path}"
      end
    end

    test "every :admin live route renders the shell with the right active mark", %{
      conn: conn,
      version: version,
      org: org,
      wallet: wallet,
      gateway: gateway,
      flag: flag
    } do
      # The enumeration, from the router itself: a new :admin live
      # route without a shell expectation fails here. /admin is the
      # redirect head (its bounce is pinned below) and rides the same
      # module as /admin/people. The resources console's surfaces are
      # domain-divided navigation (D3 revised): the landing and domain
      # pages mark the Resources entry, a resource's own surfaces mark
      # the resource LEAF (page on the index, location on its
      # sub-routes) while the entry goes quiet.
      expected = %{
        {FluxValeWeb.AdminLive.People, "/admin/people"} => {"people", "page"},
        {FluxValeWeb.AdminLive.Catalog, "/admin/catalog"} => {"catalog", "page"},
        {FluxValeWeb.AdminLive.Billing, "/admin/billing"} => {"wallets", "page"},
        {FluxValeWeb.AdminLive.WalletDetail, "/admin/billing/wallets/:id"} =>
          {"wallets", "location"},
        {FluxValeWeb.AdminLive.Orgs, "/admin/orgs"} => {"orgs", "page"},
        {FluxValeWeb.AdminLive.OrgDetail, "/admin/orgs/:id"} => {"orgs", "location"},
        {FluxValeWeb.AdminLive.Sizes, "/admin/catalog/sizes"} => {"catalog", "location"},
        {FluxValeWeb.AdminLive.SizeEdit, "/admin/catalog/sizes/:id"} => {"catalog", "location"},
        {FluxValeWeb.AdminLive.VersionEdit, "/admin/catalog/versions/:id"} =>
          {"catalog", "location"},
        {FluxValeWeb.AdminLive.Moderation, "/admin/moderation"} => {"feedback", "page"},
        {FluxValeWeb.AdminLive.Gateways, "/admin/gateways"} => {"gateways", "page"},
        {FluxValeWeb.AdminLive.GatewayDetail, "/admin/gateways/:id"} => {"gateways", "location"},
        {FluxValeWeb.AdminLive.StorageRequests, "/admin/storage-requests"} =>
          {"storage-requests", "page"},
        {FluxValeWeb.AdminLive.Audit, "/admin/audit"} => {"audit", "page"},
        {FluxValeWeb.AdminLive.Health, "/admin/health"} => {"health", "page"},
        {FluxValeWeb.AdminLive.Resources, "/admin/resources"} => {"resources", "page"},
        {FluxValeWeb.AdminLive.Resources, "/admin/resources/:domain"} =>
          {"resources", "location"},
        {FluxValeWeb.AdminLive.Resources, "/admin/resources/:domain/:resource"} =>
          {"resource-ops-feature_flag", "page"},
        {FluxValeWeb.AdminLive.Resources, "/admin/resources/:domain/:resource/new"} =>
          {"resource-ops-feature_flag", "location"},
        {FluxValeWeb.AdminLive.Resources, "/admin/resources/:domain/:resource/:id/edit"} =>
          {"resource-ops-feature_flag", "location"},
        {FluxValeWeb.AdminLive.Resources, "/admin/resources/:domain/:resource/:id"} =>
          {"resource-ops-feature_flag", "location"}
      }

      admin_routes =
        for {path, {mod, _action, _info, _session}} <- admin_live_route_info() do
          {mod, path}
        end

      # The shell's full live route set: the pre-console surfaces, one
      # pair per landed section (#603 orgs, #608 gateways, #250 storage
      # requests), the console's six (four reads + :new + :edit), #645's
      # audit window, and #702's health section. A new admin route that
      # skips the expected map below fails the fetch, not just this
      # count.
      assert length(admin_routes) == 21

      for {mod, path} <- admin_routes do
        {key, mark} = Map.fetch!(expected, {mod, path})

        concrete_path =
          concrete_admin_path(path, %{
            version: version,
            org: org,
            wallet: wallet,
            gateway: gateway,
            flag: flag
          })

        {:ok, view, _html} = live(conn, concrete_path)

        assert view.module == mod, "#{concrete_path} should mount #{inspect(mod)}"

        assert has_element?(view, "[data-testid='admin-sidebar']"),
               "#{concrete_path} should render the shell"

        entry = render(element(view, "[data-testid='admin-nav-#{key}']"))
        assert entry =~ ~s(aria-current="#{mark}"), "#{concrete_path} marks #{key} #{mark}"
      end
    end
  end

  describe "the console lane is flush (#593)" do
    # The layout fix rides the shared frame, not per-section patches:
    # every admin surface renders the unbounded chrome (`wide`) and
    # the `appgram console` root, which opts its wraps out of the
    # centered 64rem measure (app_grammar.css). max-w-5xl is the
    # header row's own marketing-era measure — its absence there is
    # the flush-header evidence, scoped to that element so unrelated
    # content can never flip the assert.
    test "every admin surface renders the console root and the unbounded chrome", %{
      conn: conn,
      version: version,
      org: org,
      wallet: wallet,
      gateway: gateway,
      flag: flag
    } do
      for {path, {_mod, _action, _info, _session}} <- admin_live_route_info() do
        {:ok, view, _html} =
          live(
            conn,
            concrete_admin_path(path, %{
              version: version,
              org: org,
              wallet: wallet,
              gateway: gateway,
              flag: flag
            })
          )

        assert has_element?(view, ".appgram.console"),
               "#{path} should opt into the console measure"

        assert has_element?(view, "header > div.flex.h-14"),
               "#{path} should render the unbounded header row"

        refute has_element?(view, "header > div.max-w-5xl"),
               "#{path} should render no centered chrome measure in the header row"
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

  describe "the Coming grammar is retired" do
    test "every section links, nothing is badged, on a live surface", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/people")

      # The completion flip (#608): all six sections live, zero Coming
      # entries. The console renders a link per entry and fails loudly
      # on a path-less one rather than promising quietly.
      for key <- ["wallets", "feedback", "orgs", "gateways"] do
        refute has_element?(view, "[data-testid='admin-coming-#{key}']")
      end

      assert has_element?(view, "[data-testid='admin-nav-wallets'][href='/admin/billing']")
      assert has_element?(view, "[data-testid='admin-nav-feedback'][href='/admin/moderation']")
      assert has_element?(view, "[data-testid='admin-nav-orgs'][href='/admin/orgs']")
      assert has_element?(view, "[data-testid='admin-nav-gateways'][href='/admin/gateways']")
      refute render(view) =~ "Coming"
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
      address = AccountsFixtures.primary_address!(admin)
      pat = ApiPat.mint!(address, ["instances:read"])
      conn = put_req_header(build_conn(), "authorization", "Bearer " <> pat)

      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/admin/people")
    end

    test "the same arm on /admin itself — the redirect head owns that path", %{admin: admin} do
      # on_mount runs before the mount callback, so the gate's bounce
      # wins over the :home head's push_navigate to /admin/people.
      address = AccountsFixtures.primary_address!(admin)
      pat = ApiPat.mint!(address, ["instances:read"])
      conn = put_req_header(build_conn(), "authorization", "Bearer " <> pat)

      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/admin")
    end
  end
end
