defmodule FluxValeWeb.OrganizationLive.AccessTest do
  @moduledoc false

  # The Access tab's gateway panel (#273, ADR-0039): the lifecycle
  # through the actions, the provider Mimic-stubbed (the cluster is the
  # provider's subject — the AccessGateway changes tests own it).

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import FluxVale.TestSupport.NoK8sLeaks
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Ash.Error.Changes.StaleRecord
  alias Ash.Error.Invalid
  alias FluxVale.Accounts.Membership
  alias FluxVale.Api.Scopes
  alias FluxVale.Billing
  alias FluxVale.Clients.K8s
  alias FluxVale.Identity
  alias FluxVale.Identity.DeviceCode
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  setup %{conn: conn} do
    owner = AccountsFixtures.user!()

    # S5: the personal org's access panel lives at /settings/access —
    # `org` (a real org) hosts the panel-behavior tests through its org
    # URL; `personal` hosts the ENABLE tests, because that panel is the
    # personal org's surface and its wallet is the one its own gates
    # read (#408: every mount's enable names its own page org).
    personal = AccountsFixtures.personal_org!(owner)
    org = AccountsFixtures.owned_org!(owner)

    # The funded gates read the live ledger: each wallet funds
    # explicitly (the JIT welcome grant only ever rode the personal
    # org); the unfunded tests drain whichever their gate reads. The
    # paid-once gate reads the same ledger: a purchase credit marks
    # both orgs paid, so the tests below exercise the gates they name
    # (the never-paid shapes are built inside their own tests).
    BillingFixtures.funded_wallet!(org: org)
    BillingFixtures.funded_wallet!(org: personal)
    BillingFixtures.mark_paid!(org)
    BillingFixtures.mark_paid!(personal)

    {:ok, conn: SessionHelpers.sign_in(conn, owner), owner: owner, org: org, personal: personal}
  end

  describe "the tab and the empty state" do
    test "the owner sees the Access tab, the explainer and the key intake", %{
      conn: conn,
      org: org
    } do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid='org-settings-tab-access']", "Access")
      assert has_element?(view, "[data-testid='access-explainer']")
      assert has_element?(view, "[data-testid='access-prereqs']")
      assert has_element?(view, "[data-testid='access-price']", "$2.00/month")
      assert has_element?(view, "#access-enable-form")
      assert has_element?(view, "[data-testid='access-key-input']")
      assert has_element?(view, "[data-testid='access-domain-input']")
      assert has_element?(view, "input[type='password']")

      # Funded by the setup grant: no top-up hint. And no card —
      # nothing is provisioned yet.
      refute has_element?(view, "[data-testid='access-prefund-hint']")
      refute has_element?(view, "[data-testid='access-gateway-card']")

      refute_k8s_terms(render(view))
    end

    test "the tab nav marks Access current on this page", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      access_tab = render(element(view, "[data-testid='org-settings-tab-access']"))
      assert access_tab =~ ~s(aria-current="page")
      assert access_tab =~ "border-focus"

      general_tab = render(element(view, "[data-testid='org-settings-tab-general']"))
      refute general_tab =~ "border-focus"
    end

    test "an empty state reports the page org's wallet", %{
      conn: conn,
      org: org
    } do
      # The enable create names the page org (#408) — the hints must
      # report that wallet. Draining the page org is what lights the
      # hint on its own page.
      drain_wallet!(org)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid='access-prefund-hint']")
      assert has_element?(view, "[data-testid='access-prefund-link']")
    end

    test "enabling from an org page lands the gateway in the page org and bills its wallet", %{
      conn: conn,
      owner: owner,
      org: org,
      personal: personal
    } do
      # The divergence this closes (#408): under the old pin-the-personal
      # behavior this enable answered on the ACTOR'S PERSONAL wallet —
      # drained here, so the funded gate would refuse it. The page org is
      # funded+paid (setup), and the created row must belong to it.
      stub_provider()
      drain_wallet!(personal)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> form("#access-enable-form",
        gateway: %{auth_key: "tskey-auth-abc123", tailnet_domain: "example.ts.net"}
      )
      |> render_submit()

      assert has_element?(view, "[data-testid='access-gateway-card']")

      {:ok, gateway} = AccessGateway.get_for_organization(org.id, actor: owner)
      assert gateway.organization_id == org.id
    end

    test "a never-paid page org sees the paid-gate callout", %{conn: conn} do
      # The page org is funded but has never PAID (no purchase on its
      # ledger): the paid-once gate's hint must show — the gate reads
      # the page org's wallet (#408), wherever the actor's personal
      # wallet stands (here paid and funded on its welcome credit).
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      personal = AccountsFixtures.personal_org!(owner)

      BillingFixtures.funded_wallet!(org: org)
      BillingFixtures.funded_wallet!(org: personal)
      BillingFixtures.mark_paid!(personal)

      {:ok, view, _html} =
        live(SessionHelpers.sign_in(conn, owner), ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid='access-paid-hint']")
      assert has_element?(view, "[data-testid='access-paid-link']")
      refute has_element?(view, "[data-testid='access-prefund-hint']")
    end

    test "a paid-but-empty personal org sees the balance copy, not the paid-gate callout", %{
      conn: conn,
      personal: personal
    } do
      # The purchase credit survives the drain (the ledger is
      # append-only) — paid stands, the balance gate is what blocks.
      # The personal mount: page org and create wallet are the same.
      drain_wallet!(personal)

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      assert has_element?(view, "[data-testid='access-prefund-hint']")
      assert has_element?(view, "[data-testid='access-prefund-link']")
      refute has_element?(view, "[data-testid='access-paid-hint']")
    end

    test "a non-owner member is gated away", %{conn: conn, org: org} do
      member = AccountsFixtures.user!()

      # Sanctioned precondition: nothing in the system creates :member
      # rows yet, so the row rides the action with authorize?: false.
      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      member_conn = SessionHelpers.sign_in(conn, member)

      assert {:error, {:live_redirect, %{flash: flash, to: "/"}}} =
               live(member_conn, ~p"/organizations/#{org.slug}/settings/access")

      assert flash["error"] == "Only organization owners can access settings."
    end

    test "an unknown slug reads as not-here", %{conn: conn} do
      assert {:error, {:live_redirect, %{flash: flash, to: "/"}}} =
               live(conn, ~p"/organizations/no-such-org/settings/access")

      assert flash["error"] == "Organization not found."
    end
  end

  # The account cluster's section sidebar (#551): the personal head
  # renders it with its own entry marked; the org head keeps the org
  # rail — one navigation system per surface.
  describe "the account sidebar" do
    test "the personal head marks Access current, the other entries quiet", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/access")

      assert view.module == FluxValeWeb.OrganizationLive.Access

      assert has_element?(view, "[data-testid='account-settings-sidebar']")

      access = render(element(view, "[data-testid='account-settings-nav-access']"))
      assert access =~ ~s(aria-current="page")
      assert access =~ ~s(href="/settings/access")

      for key <- ["profile", "wallet"] do
        quiet = render(element(view, "[data-testid='account-settings-nav-#{key}']"))
        refute quiet =~ "aria-current", "#{key} should stay quiet"
      end
    end

    test "the org head keeps the org rail — no account sidebar", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid='org-settings-tabs']")
      refute has_element?(view, "[data-testid='account-settings-sidebar']")
    end
  end

  # The ENABLE describe rides the personal panel (/settings/access): the
  # personal org is the page org there, so its wallet is what the gates
  # and hints read (#408: every mount names its own page org). The actor
  # owns EXACTLY that org: the canonical op reads the #408 marker, which
  # provisioning stamped on the signup org, and every assertion here
  # reads the pick.
  describe "enabling private access" do
    setup %{conn: conn} do
      owner = AccountsFixtures.user!()
      personal = AccountsFixtures.personal_org!(owner)

      BillingFixtures.funded_wallet!(org: personal)
      # The create's paid-once gate reads the personal org too (the
      # actor path) — these tests exercise the enable flow, not the
      # paid gate (the unfunded test below drains and still forbids).
      BillingFixtures.mark_paid!(personal)
      stub_provider()

      {:ok, owner: owner, personal: personal, conn: SessionHelpers.sign_in(conn, owner)}
    end

    test "a funded org's key lands a connecting gateway at the config price", %{
      conn: conn,
      owner: owner,
      personal: personal
    } do
      stub_provider()

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      view
      |> form("#access-enable-form",
        gateway: %{auth_key: "tskey-auth-abc123", tailnet_domain: "example.ts.net"}
      )
      |> render_submit()

      assert has_element?(view, "[data-testid='access-gateway-card']")
      assert has_element?(view, "[data-testid=status-badge]", "Connecting")
      assert has_element?(view, "[data-testid='access-connecting-note']")
      assert has_element?(view, "[data-testid='access-hostname']")
      refute has_element?(view, "[data-testid='access-empty']")

      {:ok, gateway} = AccessGateway.get_for_organization(personal.id, actor: owner)

      assert gateway.hostname =~ ~r/\Afv-[0-9a-f]{8}\z/

      # The row snapshots the panel's price — the same number the empty
      # state displayed.
      assert gateway.monthly_cents ==
               Application.fetch_env!(:flux_vale, :access_gateway)[:monthly_cents]
    end

    test "typing a key validates without creating anything", %{conn: conn, personal: personal} do
      stub_provider()

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      view
      |> form("#access-enable-form",
        gateway: %{auth_key: "tskey-auth-typing", tailnet_domain: "example.ts.net"}
      )
      |> render_change()

      assert has_element?(view, "#access-enable-form")
      refute has_element?(view, "[data-testid='access-gateway-card']")

      assert {:error, _none} =
               AccessGateway.get_for_organization(personal.id, authorize?: false)
    end

    test "an unfunded org's enable attempt answers with the top-up copy", %{
      conn: conn,
      personal: personal
    } do
      # The create's funded gate reads the page org's wallet (#408) —
      # the personal org, on this mount.
      drain_wallet!(personal)

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      view
      |> form("#access-enable-form",
        gateway: %{auth_key: "tskey-auth-abc123", tailnet_domain: "example.ts.net"}
      )
      |> render_submit()

      assert has_element?(view, "#flash-error", "Top up before enabling private access")

      # No row: the policy gate answered before any work ran.
      assert {:error, _none} =
               AccessGateway.get_for_organization(personal.id, authorize?: false)
    end

    test "a never-paid org's enable attempt answers with the top-up copy", %{
      conn: conn
    } do
      # The paid-once gate, driven through the panel: the fresh user's
      # personal org holds its JIT welcome credit (funded) but has never
      # PAID — the funded gate alone would let this click through.
      owner = AccountsFixtures.user!()
      personal = AccountsFixtures.personal_org!(owner)

      {:ok, view, _html} = live(SessionHelpers.sign_in(conn, owner), ~p"/settings/access")

      view
      |> form("#access-enable-form",
        gateway: %{auth_key: "tskey-auth-abc123", tailnet_domain: "example.ts.net"}
      )
      |> render_submit()

      assert has_element?(view, "#flash-error", "Top up before enabling private access")

      # No row: the policy gate answered before any work ran.
      assert {:error, _none} =
               AccessGateway.get_for_organization(personal.id, authorize?: false)
    end

    test "a failed provisioning re-renders the form and leaves no row", %{
      conn: conn,
      personal: personal
    } do
      stub_provider()

      expect(Tailscale, :provision_gateway, fn _gateway, _key -> {:error, :cluster_down} end)
      stub(Tailscale, :cleanup_failed_provision, fn _gateway -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      view
      |> form("#access-enable-form",
        gateway: %{auth_key: "tskey-auth-abc123", tailnet_domain: "example.ts.net"}
      )
      |> render_submit()

      # The failure is a flash, never a silent dead click.
      assert has_element?(view, "#flash-error", "Couldn't enable private access")
      assert has_element?(view, "#access-enable-form")
      refute has_element?(view, "[data-testid='access-gateway-card']")

      # A failed create rolls the row back — the owner's retry is the
      # same form.
      assert {:error, _none} =
               AccessGateway.get_for_organization(personal.id, authorize?: false)
    end

    test "the typed key never echoes into the markup", %{conn: conn} do
      stub_provider()

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      # The validate round-trip is a read-back if the value re-renders
      # (ADR-0039 §4): the typed marker must not appear in the patch or
      # the markup.
      view
      |> form("#access-enable-form",
        gateway: %{auth_key: "tskey-TYPING-marker", tailnet_domain: "example.ts.net"}
      )
      |> render_change()

      refute render(view) =~ "tskey-TYPING-marker"

      # Typing still works: a submit right after lands the gateway.
      view
      |> form("#access-enable-form",
        gateway: %{auth_key: "tskey-auth-final", tailnet_domain: "example.ts.net"}
      )
      |> render_submit()

      assert has_element?(view, "[data-testid='access-gateway-card']")
    end

    test "a failed re-paste leaves no key echo in the markup", %{
      conn: conn,
      personal: personal
    } do
      stub_provider()

      AccessFixtures.gateway!(personal, state: :needs_attention)

      expect(Tailscale, :update_credential, fn _gateway, _key -> {:error, :cluster_down} end)

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      view
      |> form("#access-repaste-form",
        gateway: %{auth_key: "tskey-SECRET-marker", tailnet_domain: "example.ts.net"}
      )
      |> render_submit()

      # The failure names itself and the form stays open for the retry —
      # without carrying the submitted key anywhere.
      assert has_element?(view, "#flash-error", "Couldn't update the access key")
      assert has_element?(view, "#access-repaste-form")
      refute render(view) =~ "tskey-SECRET-marker"
    end
  end

  describe "the gateway card per state" do
    setup do
      stub_provider()
    end

    test ":active — badge, hostname, billing line, collapsed re-paste, armed remove", %{
      conn: conn,
      org: org
    } do
      gateway = AccessFixtures.gateway!(org)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid='access-gateway-card']")
      assert has_element?(view, "[data-testid=status-badge]", "Connected")
      assert has_element?(view, "[data-testid='access-hostname']", gateway.hostname)
      assert has_element?(view, "[data-testid='access-status-message']", "Connected")
      assert has_element?(view, "[data-testid='access-billing-line']", "$2.00/month")

      # Collapsed by default: the toggle is there, the form is not.
      assert has_element?(view, "[data-testid='access-repaste-toggle']", "Re-paste key")
      refute has_element?(view, "#access-repaste-form")

      # Remove starts unarmed.
      assert has_element?(view, "[data-testid='access-remove']")
      refute has_element?(view, "[data-testid='access-remove-confirm']")

      refute_k8s_terms(render(view))
    end

    test ":provisioning — the honest copy and the reconnect affordance", %{conn: conn, org: org} do
      AccessFixtures.gateway!(org, state: :provisioning)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid=status-badge]", "Connecting")

      # No time promise without a view of the clock: the copy names the
      # stuck path and the key that fixes it (update_credential's drift
      # repair is the engine half).
      assert has_element?(
               view,
               "[data-testid='access-connecting-note']",
               "If it sticks, reconnect with your key"
             )

      assert has_element?(view, "[data-testid='access-repaste-toggle']", "Re-paste key")

      # No remove on this card: the reconnect works, and the row is not
      # going away.
      refute has_element?(view, "[data-testid='access-remove']")
    end

    test ":needs_attention — the reconnect surface is open and prominent", %{
      conn: conn,
      org: org
    } do
      AccessFixtures.gateway!(org, state: :needs_attention)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid=status-badge]", "Needs attention")
      assert has_element?(view, "[data-testid='access-attention-note']")

      # The recovery is the page's primary act — the form is open
      # outright, no toggle step.
      assert has_element?(view, "#access-repaste-form")
      assert has_element?(view, "[data-testid='access-repaste-submit']", "Reconnect")
      assert has_element?(view, "[data-testid='access-remove']")
    end

    test ":suspended — the banner and the funded resume", %{conn: conn, org: org} do
      AccessFixtures.gateway!(org, state: :suspended)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid=status-badge]", "Suspended")
      assert has_element?(view, "[data-testid='access-suspended-banner']")
      assert has_element?(view, "[data-testid='access-suspended-banner']", "The balance ran out")
      assert has_element?(view, "[data-testid='access-resume']")
      refute has_element?(view, "[data-testid='access-resume-topup']")
      assert has_element?(view, "[data-testid='access-remove']")

      refute_k8s_terms(render(view))
    end

    test ":suspended unfunded — the top-up copy replaces the resume button", %{
      conn: conn,
      org: org
    } do
      AccessFixtures.gateway!(org, state: :suspended)
      drain_wallet!(org)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid='access-suspended-banner']")
      refute has_element?(view, "[data-testid='access-resume']")
      assert has_element?(view, "[data-testid='access-resume-topup']")
      assert has_element?(view, "[data-testid='access-resume-topup-link']")
    end

    test ":suspended never-paid — the top-up copy replaces the resume button too", %{
      conn: conn
    } do
      # The legacy shape (a fresh org — the setup orgs are marked paid):
      # suspended on a never-paid org — resume would be Forbidden, so
      # the button never shows. Welcome-only positive balance: funded,
      # never paid. (User first, then the real org — the S5
      # personal-org route would redirect.)
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      welcome_only!(org)
      AccessFixtures.gateway!(org, state: :suspended)

      {:ok, view, _html} =
        live(SessionHelpers.sign_in(conn, owner), ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid='access-suspended-banner']")
      refute has_element?(view, "[data-testid='access-resume']")
      assert has_element?(view, "[data-testid='access-resume-topup']")
    end

    test ":suspended resume affordance keys on the ROW's org, not the actor's personal org", %{
      conn: conn
    } do
      # The resume spends the ROW's org: B holds the suspended gateway
      # and is never-paid on welcome credit alone, while the actor's
      # personal org is paid+-funded. If the panel read the personal
      # wallet here, the button would show and the click would be
      # Forbidden — the row's wallet decides.
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      welcome_only!(org)
      AccessFixtures.gateway!(org, state: :suspended)

      personal = AccountsFixtures.personal_org!(owner)
      BillingFixtures.mark_paid!(personal)

      {:ok, view, _html} =
        live(SessionHelpers.sign_in(conn, owner), ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid='access-suspended-banner']")
      refute has_element?(view, "[data-testid='access-resume']")
      assert has_element?(view, "[data-testid='access-resume-topup']")
    end

    test ":destroying — the removing note and the retry affordance", %{conn: conn, org: org} do
      AccessFixtures.gateway!(org, state: :destroying)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid=status-badge]", "Removing")
      assert has_element?(view, "[data-testid='access-removing-note']")
      # No armed remove on a row already going away — but an exhausted
      # teardown needs an owner path forward, so the retry is here.
      refute has_element?(view, "[data-testid='access-remove']")
      refute has_element?(view, "[data-testid='access-repaste']")
      assert has_element?(view, "[data-testid='access-retry-remove']", "Retry removal")
    end
  end

  describe "re-pasting the key" do
    setup do
      stub_provider()
    end

    test "the active card's collapsed form toggles open and shut", %{conn: conn, org: org} do
      gateway = AccessFixtures.gateway!(org)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> element("[data-testid='access-repaste-toggle']")
      |> render_click()

      assert has_element?(view, "#access-repaste-form")
      assert has_element?(view, "[data-testid='access-repaste-key']")
      assert has_element?(view, "input[type='password']")

      # A keystroke round-trip validates the re-paste form without
      # touching the row.
      view
      |> form("#access-repaste-form",
        gateway: %{auth_key: "tskey-auth-typing", tailnet_domain: "example.ts.net"}
      )
      |> render_change()

      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).state == :active

      view
      |> element("[data-testid='access-repaste-hide']")
      |> render_click()

      refute has_element?(view, "#access-repaste-form")
    end

    test "re-pasting a fresh key from needs_attention reconnects", %{
      conn: conn,
      owner: owner,
      org: org
    } do
      gateway = AccessFixtures.gateway!(org, state: :needs_attention)

      expect(Tailscale, :update_credential, fn _gateway, "tskey-auth-fresh" -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> form("#access-repaste-form",
        gateway: %{auth_key: "tskey-auth-fresh", tailnet_domain: "example.ts.net"}
      )
      |> render_submit()

      assert has_element?(view, "[data-testid=status-badge]", "Connecting")

      # The row left :needs_attention for :provisioning — the observed
      # write settles it from there.
      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).state == :provisioning
      assert {:ok, _still_there} = AccessGateway.get_for_organization(org.id, actor: owner)
    end

    test "a re-paste with a changed tailnet domain repairs the addresses — the P1 backfill", %{
      conn: conn,
      owner: owner,
      org: org
    } do
      # The migration-window shape: a pre-column row, seeded because no
      # action can produce a nil domain, with an attached instance —
      # exactly the live staging gateway.
      gateway =
        Ash.Seed.seed!(AccessGateway, %{
          organization_id: org.id,
          hostname: "fv-00000001",
          monthly_cents: 200,
          state: :active,
          status_message: "Connected",
          tailnet_domain: nil
        })

      # The instance create resolves the single cluster row.
      InstanceFixtures.local_cluster!()

      attached_instance = AccessFixtures.private_instance!(org, owner)

      AccessRoute.create!(
        %{gateway_id: gateway.id, instance_id: attached_instance.id, route_key: "8443"},
        authorize?: false
      )

      expect(Tailscale, :refresh_routes, fn %{tailnet_domain: domain} ->
        assert domain == "rejoined.ts.net"
        {:ok, %{}}
      end)

      expect(Tailscale, :update_credential, fn _gateway, "tskey-auth-fresh" -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      # The placeholder arm: a nil-domain row shows the placeholder, not
      # a fabricated address.
      assert has_element?(view, "[data-testid='access-attached-address']", "your-tailnet")

      # :active keeps the form collapsed behind the toggle.
      view
      |> element("[data-testid='access-repaste-toggle']")
      |> render_click()

      view
      |> form("#access-repaste-form",
        gateway: %{auth_key: "tskey-auth-fresh", tailnet_domain: "rejoined.ts.net"}
      )
      |> render_submit()

      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).tailnet_domain ==
               "rejoined.ts.net"
    end

    test "a failed re-paste keeps the state and the form", %{conn: conn, org: org} do
      gateway = AccessFixtures.gateway!(org, state: :needs_attention)

      expect(Tailscale, :update_credential, fn _gateway, _key -> {:error, :cluster_down} end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> form("#access-repaste-form",
        gateway: %{auth_key: "tskey-auth-fresh", tailnet_domain: "example.ts.net"}
      )
      |> render_submit()

      # The engine's answer reaches the owner — a flash, not a dead click.
      assert has_element?(view, "#flash-error", "Couldn't update the access key")
      assert has_element?(view, "[data-testid=status-badge]", "Needs attention")
      assert has_element?(view, "#access-repaste-form")

      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).state == :needs_attention
    end
  end

  describe "resuming a suspended gateway" do
    setup do
      stub_provider()
    end

    test "a funded resume returns the gateway to connecting", %{conn: conn, org: org} do
      gateway = AccessFixtures.gateway!(org, state: :suspended)

      expect(Tailscale, :scale_gateway, fn _gateway, 1 -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> element("[data-testid='access-resume']")
      |> render_click()

      assert has_element?(view, "[data-testid=status-badge]", "Connecting")
      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).state == :provisioning
    end

    test "a wallet drained after mount answers with the top-up copy", %{conn: conn, org: org} do
      gateway = AccessFixtures.gateway!(org, state: :suspended)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      # Funded at mount, empty at click — the engine's gate is the
      # authority; the panel's copy follows it.
      drain_wallet!(org)

      view
      |> element("[data-testid='access-resume']")
      |> render_click()

      assert has_element?(view, "#flash-error", "Top up before resuming private access")
      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).state == :suspended
    end

    test "a mid-resume failure keeps :suspended and offers the retry", %{conn: conn, org: org} do
      gateway = AccessFixtures.gateway!(org, state: :suspended)

      expect(Tailscale, :scale_gateway, fn _gateway, 1 -> {:error, :cluster_down} end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> element("[data-testid='access-resume']")
      |> render_click()

      assert has_element?(view, "#flash-error", "Could not resume private access")
      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).state == :suspended
    end

    test "a resume refused as stale says reload, not retry", %{conn: conn, org: org} do
      AccessFixtures.gateway!(org, state: :suspended)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      # The race the engine's row filter answers: this panel's struct is
      # stale by the time its resume reaches the row (another tab won).
      # Stubbed at the seam — the real filter is pinned in the
      # AccessGateway changes tests; this pins the panel's discrimination.
      Mimic.copy(AccessGateway)

      stub(AccessGateway, :resume, fn _gateway, _opts ->
        {:error, Invalid.exception(errors: [%StaleRecord{}])}
      end)

      view
      |> element("[data-testid='access-resume']")
      |> render_click()

      assert has_element?(view, "#flash-error", "changed underneath you")
    end
  end

  describe "removing the gateway" do
    setup do
      stub_provider()
    end

    test "remove is confirm-armed: a crafted click is a no-op, cancel disarms, confirm removes",
         %{
           conn: conn,
           org: org
         } do
      gateway = AccessFixtures.gateway!(org)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      # Unarmed: the confirm callout is absent and the crafted event
      # changes nothing.
      refute has_element?(view, "[data-testid='access-remove-confirm']")
      render_click(view, "remove", %{})
      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).state == :active

      # Arming shows the callout; the copy names the consequence.
      view
      |> element("[data-testid='access-remove']")
      |> render_click()

      assert has_element?(view, "[data-testid='access-remove-confirm']")
      assert has_element?(view, "#access-remove-confirm", "panel-only private")
      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).state == :active

      # Cancel disarms.
      view
      |> element("[data-testid='access-cancel-remove']")
      |> render_click()

      refute has_element?(view, "[data-testid='access-remove-confirm']")
      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).state == :active

      # Arm and confirm: the row goes :destroying and the inline
      # teardown finishes the job — the hard delete lands the empty
      # state.
      view
      |> element("[data-testid='access-remove']")
      |> render_click()

      view
      |> element("[data-testid='access-confirm-remove']")
      |> render_click()

      assert {:error, _gone} = AccessGateway.get_for_organization(org.id, authorize?: false)
      assert has_element?(view, "[data-testid='access-empty']")
      assert has_element?(view, "#access-enable-form")
    end

    test "a remove that fails answers with the retry copy", %{conn: conn, org: org} do
      gateway = AccessFixtures.gateway!(org)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      Mimic.copy(Infrastructure)
      stub(Infrastructure, :delete_access_gateway, fn _id, _opts -> {:error, :cluster_down} end)

      view
      |> element("[data-testid='access-remove']")
      |> render_click()

      view
      |> element("[data-testid='access-confirm-remove']")
      |> render_click()

      assert has_element?(view, "#flash-error", "Could not remove private access")
      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).state == :active
    end

    test "a double-click on Retry removal survives the empty state", %{conn: conn, org: org} do
      AccessFixtures.gateway!(org, state: :destroying)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      # The first click enqueues; the inline teardown hard-deletes the
      # row and its broadcast lands the empty state.
      view
      |> element("[data-testid='access-retry-remove']")
      |> render_click()

      assert has_element?(view, "[data-testid='access-empty']")

      # The second click of the double arrives with the panel already
      # empty — a no-op, never a crash.
      render_click(view, "retry-remove", %{})

      assert has_element?(view, "[data-testid='access-empty']")
    end

    test "the remove family is inert on an emptied panel", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      render_click(view, "arm-remove", %{})
      render_click(view, "remove", %{})
      render_click(view, "retry-remove", %{})

      assert has_element?(view, "[data-testid='access-empty']")
    end

    test "retrying a removal re-enqueues and lands the empty state", %{conn: conn, org: org} do
      AccessFixtures.gateway!(org, state: :destroying)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      # One click: the engine's delete re-enqueues idempotently from
      # :destroying, and the inline teardown finishes the job.
      view
      |> element("[data-testid='access-retry-remove']")
      |> render_click()

      assert has_element?(view, "[data-testid='access-empty']")
      assert has_element?(view, "#access-enable-form")
    end

    test "a retry that fails answers with the retry copy", %{conn: conn, org: org} do
      gateway = AccessFixtures.gateway!(org, state: :destroying)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      Mimic.copy(Infrastructure)
      stub(Infrastructure, :delete_access_gateway, fn _id, _opts -> {:error, :cluster_down} end)

      view
      |> element("[data-testid='access-retry-remove']")
      |> render_click()

      assert has_element?(view, "#flash-error", "Could not remove private access")
      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).state == :destroying
    end
  end

  describe "live updates" do
    setup do
      stub_provider()
    end

    test "a state broadcast refetches the panel — and opens the recovery", %{conn: conn, org: org} do
      gateway = AccessFixtures.gateway!(org)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid=status-badge]", "Connected")
      refute has_element?(view, "#access-repaste-form")

      # The observed-state write — the same funnel production uses —
      # publishes to the per-org topic. (Each write chains from the
      # fresh row: a second write from the stale struct would be a
      # no-op — Ash skips writes with no changes against their own
      # record.)
      needs_attention =
        gateway
        |> Ash.Changeset.for_update(
          :update_state,
          %{state: :needs_attention, status_message: "Gateway not reachable"},
          authorize?: false
        )
        |> Ash.update!()

      assert has_element?(view, "[data-testid=status-badge]", "Needs attention")
      assert has_element?(view, "#access-repaste-form")

      # And back: the observer promotes again.
      needs_attention
      |> Ash.Changeset.for_update(:update_state, %{state: :active}, authorize?: false)
      |> Ash.update!()

      assert has_element?(view, "[data-testid=status-badge]", "Connected")
    end

    test "the teardown's hard delete lands the empty state", %{conn: conn, org: org} do
      gateway = AccessFixtures.gateway!(org)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid='access-gateway-card']")

      # The system-only hard delete (teardown's terminal write) — its
      # publish is the one event the :update_state funnel never carries.
      gateway
      |> Ash.Changeset.for_destroy(:destroy_after_teardown, %{}, authorize?: false)
      |> Ash.destroy!()

      assert has_element?(view, "[data-testid='access-empty']")
      assert has_element?(view, "#access-enable-form")
      refute has_element?(view, "[data-testid='access-gateway-card']")
    end

    test "a same-state broadcast keeps the panel — and the typed key — untouched", %{
      conn: conn,
      org: org
    } do
      gateway = AccessFixtures.gateway!(org)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> element("[data-testid='access-repaste-toggle']")
      |> render_click()

      view
      |> form("#access-repaste-form",
        gateway: %{auth_key: "tskey-auth-typing", tailnet_domain: "example.ts.net"}
      )
      |> render_change()

      # The observer writes every minute while :active and always
      # publishes (the reconciler's stance) — the panel refetches
      # silently and must not rebuild the form out from under the
      # half-typed key.
      gateway
      |> Ash.Changeset.for_update(
        :update_state,
        %{status_message: "Connected to your tailnet"},
        authorize?: false
      )
      |> Ash.update!()

      assert has_element?(view, "[data-testid=status-badge]", "Connected")
      assert has_element?(view, "#access-repaste-form")
      assert has_element?(view, "[data-testid='access-remove']")
    end

    test "the ladder's suspension lands the suspended banner live", %{conn: conn, org: org} do
      gateway = AccessFixtures.gateway!(org)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid=status-badge]", "Connected")

      # The zero-balance ladder's arm: force-changes on the :suspend
      # action (never the :update_state funnel), authorize?: false —
      # and its publish is what moves an open panel. (The wallet here
      # stays funded: what's under test is the publish-driven panel
      # transition, and a funded org renders the Resume button.)
      gateway
      |> Ash.Changeset.for_update(:suspend, %{}, authorize?: false)
      |> Ash.update!()

      assert has_element?(view, "[data-testid=status-badge]", "Suspended")
      assert has_element?(view, "[data-testid='access-suspended-banner']")
      assert has_element?(view, "[data-testid='access-resume']")
    end

    test "a resume from another tab lands connecting live", %{conn: conn, owner: owner, org: org} do
      gateway = AccessFixtures.gateway!(org, state: :suspended)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid=status-badge]", "Suspended")

      # The same row resumed elsewhere: this panel follows on the
      # publish, not a reload.
      AccessGateway.resume(gateway, actor: owner)

      assert has_element?(view, "[data-testid=status-badge]", "Connecting")
      refute has_element?(view, "[data-testid='access-resume']")
    end

    test "a re-paste from another tab lands connecting live", %{conn: conn, org: org} do
      gateway = AccessFixtures.gateway!(org, state: :needs_attention)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid=status-badge]", "Needs attention")

      # The same row re-pasted elsewhere: the :update_credential publish
      # moves this panel off the reconnect surface too.
      AccessGateway.update_credential(gateway, %{auth_key: "tskey-auth-elsewhere"},
        authorize?: false
      )

      assert has_element?(view, "[data-testid=status-badge]", "Connecting")
      refute has_element?(view, "#access-repaste-form")
    end

    test "a provision exhaustion lands its copy and opens the recovery live", %{
      conn: conn,
      org: org
    } do
      gateway = AccessFixtures.gateway!(org, state: :provisioning)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid=status-badge]", "Connecting")

      gateway
      |> Ash.Changeset.for_update(:mark_provision_error, %{error: %{}}, authorize?: false)
      |> Ash.update!()

      # The publish carries the state write: the badge flips and the
      # recovery opens without a reload.
      assert has_element?(view, "[data-testid=status-badge]", "Needs attention")
      assert has_element?(view, "#access-repaste-form")

      assert has_element?(
               view,
               "[data-testid='access-status-message']",
               "Try connecting again"
             )
    end

    test "a teardown exhaustion lands its copy live", %{conn: conn, org: org} do
      gateway = AccessFixtures.gateway!(org, state: :destroying)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      gateway
      |> Ash.Changeset.for_update(:mark_teardown_error, %{error: %{}}, authorize?: false)
      |> Ash.update!()

      assert has_element?(view, "[data-testid='access-status-message']", "Removal failed")
      assert has_element?(view, "[data-testid='access-retry-remove']")
    end
  end

  describe "pairing instances (ADR-0039 §3, §4.1)" do
    setup do
      stub_provider()
      # The instance fixtures resolve placement (ResolveCluster's
      # exactly-one-cluster contract).
      InstanceFixtures.local_cluster!()

      :ok
    end

    test "an active gateway shows both sections with their rows", %{
      conn: conn,
      owner: owner,
      org: org
    } do
      gateway = AccessFixtures.gateway!(org)
      attached_instance = AccessFixtures.private_instance!(org, owner)
      waiting = AccessFixtures.private_instance!(org, owner)

      # The pairing row the provider's attach writes — create is
      # system-only, so the row is seeded directly (the wake tests'
      # sanctioned precondition).
      AccessRoute.create!(
        %{gateway_id: gateway.id, instance_id: attached_instance.id, route_key: "8443"},
        authorize?: false
      )

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      # Attached row: name, live address (hostname + the row's tailnet
      # domain + port — the concrete FQDN the gateway serves, P1), and
      # the no-confirm Detach with its reversible-consequence copy.
      assert has_element?(view, "[data-testid='access-attached-row']", attached_instance.name)
      assert has_element?(view, "[data-testid='access-attached-address']", gateway.hostname)
      assert has_element?(view, "[data-testid='access-attached-address']", "8443")

      assert has_element?(
               view,
               "[data-testid='access-attached-address']",
               "#{gateway.hostname}.#{gateway.tailnet_domain}:8443"
             )

      assert has_element?(view, "[data-testid='access-detach']")

      assert has_element?(
               view,
               "[data-testid='access-attached']",
               "reachable from the panel only again"
             )

      # The waiting half: exactly the unattached private instance.
      assert has_element?(view, "[data-testid='access-attach-row']", waiting.name)
      assert has_element?(view, "[data-testid='access-attach-button']")

      refute has_element?(view, "[data-testid='access-attached-empty']")
      refute has_element?(view, "[data-testid='access-attach-empty']")
      refute_k8s_terms(render(view))
    end

    test "empty sections say so; a public instance never waits to attach", %{
      conn: conn,
      owner: owner,
      org: org
    } do
      AccessFixtures.gateway!(org)
      AccessFixtures.public_instance!(org, owner)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid='access-attached-empty']")
      assert has_element?(view, "[data-testid='access-attach-empty']")
      refute has_element?(view, "[data-testid='access-attached-row']")
      refute has_element?(view, "[data-testid='access-attach-row']")
    end

    test "attach pairs the app through the panel and shows its address", %{
      conn: conn,
      owner: owner,
      org: org
    } do
      AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      expect(Tailscale, :attach_instance, fn %AccessGateway{} = gw, %Instance{} = inst ->
        # The stub plays the provider's row-create; the cluster limbs
        # are the provider tests' subject (this suite's stance).
        {:ok,
         AccessRoute.create!(
           %{gateway_id: gw.id, instance_id: inst.id, route_key: "8443"},
           authorize?: false
         )}
      end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> element("[data-testid='access-attach-button']")
      |> render_click()

      assert has_element?(view, "#flash-info", "#{instance.name} attached")
      assert has_element?(view, "[data-testid='access-attached-row']", instance.name)
      refute has_element?(view, "[data-testid='access-attach-row']")

      assert {:ok, _route} = AccessRoute.get_by_instance(instance.id, authorize?: false)
    end

    test "attach while the gateway went dark answers wait-for-Connected", %{
      conn: conn,
      owner: owner,
      org: org
    } do
      AccessFixtures.gateway!(org)
      AccessFixtures.private_instance!(org, owner)

      expect(Tailscale, :attach_instance, fn _gateway, _instance ->
        {:error, :gateway_not_active}
      end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> element("[data-testid='access-attach-button']")
      |> render_click()

      assert has_element?(view, "[data-testid='access-attach-error']", "Wait for Connected")
    end

    test "an exhausted pool lands its honest copy", %{conn: conn, owner: owner, org: org} do
      AccessFixtures.gateway!(org)
      AccessFixtures.private_instance!(org, owner)

      expect(Tailscale, :attach_instance, fn _gateway, _instance ->
        {:error, :pool_exhausted}
      end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> element("[data-testid='access-attach-button']")
      |> render_click()

      assert has_element?(view, "[data-testid='access-attach-error']", "addresses are all in use")
    end

    test "a gateway with no tailnet domain yet answers with the backfill copy", %{
      conn: conn,
      owner: owner,
      org: org
    } do
      # The migration-window row: seeded because no action produces a
      # nil domain anymore. Its attach is refused by the provider until
      # the owner re-pastes with the domain filled in.
      Ash.Seed.seed!(AccessGateway, %{
        organization_id: org.id,
        hostname: "fv-00000002",
        monthly_cents: 200,
        state: :active,
        status_message: "Connected",
        tailnet_domain: nil
      })

      AccessFixtures.private_instance!(org, owner)

      expect(Tailscale, :attach_instance, fn _gateway, _instance ->
        {:error, :tailnet_domain_missing}
      end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> element("[data-testid='access-attach-button']")
      |> render_click()

      assert has_element?(
               view,
               "[data-testid='access-attach-error']",
               "needs its tailnet domain"
             )
    end

    test "a cluster failure lands the try-again copy", %{conn: conn, owner: owner, org: org} do
      AccessFixtures.gateway!(org)
      AccessFixtures.private_instance!(org, owner)

      expect(Tailscale, :attach_instance, fn _gateway, _instance ->
        {:error, :cluster_down}
      end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> element("[data-testid='access-attach-button']")
      |> render_click()

      assert has_element?(view, "[data-testid='access-attach-error']", "Couldn't attach")
    end

    test "detach is a bare click — no confirm — and the app returns to the waiting list", %{
      conn: conn,
      owner: owner,
      org: org
    } do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      AccessRoute.create!(
        %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
        authorize?: false
      )

      expect(Tailscale, :detach_instance, fn _gateway, %Instance{} = inst ->
        inst.id
        |> AccessRoute.get_by_instance!(authorize?: false)
        |> AccessRoute.destroy!(authorize?: false)

        :ok
      end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> element("[data-testid='access-detach']")
      |> render_click()

      assert has_element?(view, "#flash-info", "Reachable from the panel only again")
      refute has_element?(view, "[data-testid='access-attached-row']")
      assert has_element?(view, "[data-testid='access-attach-row']", instance.name)

      assert {:error, _gone} = AccessRoute.get_by_instance(instance.id, authorize?: false)
    end

    test "a failed detach answers with the retry copy and keeps the pairing", %{
      conn: conn,
      owner: owner,
      org: org
    } do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      AccessRoute.create!(
        %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
        authorize?: false
      )

      expect(Tailscale, :detach_instance, fn _gateway, _instance -> {:error, :cluster_down} end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> element("[data-testid='access-detach']")
      |> render_click()

      assert has_element?(view, "#flash-error", "Couldn't detach")
      assert has_element?(view, "[data-testid='access-attached-row']", instance.name)
    end

    test "a public-but-attached row lists honestly and detaches back to public", %{
      conn: conn,
      owner: owner,
      org: org
    } do
      gateway = AccessFixtures.gateway!(org)
      public = AccessFixtures.public_instance!(org, owner)

      # Attach refuses a public instance, so this row can only exist
      # out-of-band — the exposure toggle's corner the row must show
      # honestly (§4.1).
      AccessRoute.create!(
        %{gateway_id: gateway.id, instance_id: public.id, route_key: "8443"},
        authorize?: false
      )

      expect(Tailscale, :detach_instance, fn _gateway, %Instance{} = inst ->
        inst.id
        |> AccessRoute.get_by_instance!(authorize?: false)
        |> AccessRoute.destroy!(authorize?: false)

        :ok
      end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid='access-attached-row']", public.name)
      assert has_element?(view, "[data-testid='access-attached-public-note']")

      view
      |> element("[data-testid='access-detach']")
      |> render_click()

      assert has_element?(view, "#flash-info", "Its public address still works")
    end

    test "a suspended gateway hides the pairing sections and says why", %{conn: conn, org: org} do
      AccessFixtures.gateway!(org, state: :suspended)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      refute has_element?(view, "[data-testid='access-attached']")
      refute has_element?(view, "[data-testid='access-attach']")
      assert has_element?(view, "[data-testid='access-pairing-paused']")
      assert has_element?(view, "[data-testid='access-pairing-paused']", "suspended")
    end

    test "a needs_attention gateway hides the sections with its own line", %{conn: conn, org: org} do
      AccessFixtures.gateway!(org, state: :needs_attention)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      refute has_element?(view, "[data-testid='access-attached']")
      refute has_element?(view, "[data-testid='access-attach']")

      assert has_element?(
               view,
               "[data-testid='access-pairing-paused']",
               "Reconnect with a fresh key"
             )
    end

    test "a destroying gateway hides the sections with its own line", %{conn: conn, org: org} do
      AccessFixtures.gateway!(org, state: :destroying)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      refute has_element?(view, "[data-testid='access-attached']")
      refute has_element?(view, "[data-testid='access-attach']")
      assert has_element?(view, "[data-testid='access-pairing-paused']", "being removed")
    end

    test "a suspension broadcast hides the sections live; restoring brings them back", %{
      conn: conn,
      owner: owner,
      org: org
    } do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      AccessRoute.create!(
        %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
        authorize?: false
      )

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid='access-attached-row']")

      # Each write chains from the fresh row — a second write from the
      # stale struct is a no-op (Ash skips no-change writes), and the
      # publish is what moves the panel.
      suspended =
        gateway
        |> Ash.Changeset.for_update(:update_state, %{state: :suspended}, authorize?: false)
        |> Ash.update!()

      refute has_element?(view, "[data-testid='access-attached']")
      assert has_element?(view, "[data-testid='access-pairing-paused']")

      suspended
      |> Ash.Changeset.for_update(:update_state, %{state: :active}, authorize?: false)
      |> Ash.update!()

      assert has_element?(view, "[data-testid='access-attached-row']")
      refute has_element?(view, "[data-testid='access-pairing-paused']")
    end

    test "pairing events are inert without a gateway", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      render_click(view, "attach", %{"instance_id" => Ecto.UUID.generate()})
      render_click(view, "detach", %{"instance_id" => Ecto.UUID.generate()})

      assert has_element?(view, "[data-testid='access-empty']")
    end

    # Crafted payloads (no instance_id at all) must be total no-ops — the
    # handler family's stated stance (hostile review: these raised
    # FunctionClauseError before the catch-alls).
    test "crafted pairing events without an instance_id are no-ops, never crashes", %{
      conn: conn,
      org: org
    } do
      AccessFixtures.gateway!(org)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert render_click(view, "attach", %{}) =~ "Attached apps"
      assert render_click(view, "detach", %{}) =~ "Attached apps"
    end

    test "stale clicks on vanished instances land the copy, never a crash", %{
      conn: conn,
      org: org
    } do
      AccessFixtures.gateway!(org)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      render_click(view, "attach", %{"instance_id" => Ecto.UUID.generate()})
      assert has_element?(view, "[data-testid='access-attach-error']", "Couldn't attach")

      render_click(view, "detach", %{"instance_id" => Ecto.UUID.generate()})
      assert has_element?(view, "#flash-error", "Couldn't detach")
    end

    # CodeRabbit round: a stale row must leave with its failed click —
    # the lists re-read, the ghost does not re-fail forever.
    test "a stale attach click drops the vanished row from the waiting list", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      AccessFixtures.gateway!(org)
      ghost = AccessFixtures.private_instance!(org, owner)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "#access-attach-#{ghost.id}")

      Ash.destroy!(ghost, authorize?: false)

      render_click(view, "attach", %{"instance_id" => ghost.id})
      assert has_element?(view, "[data-testid='access-attach-error']", "Couldn't attach")
      refute has_element?(view, "#access-attach-#{ghost.id}")
    end
  end

  # The gateway lifecycle's provider legs, Mimic-stubbed for every test
  # that mounts the panel with a fixture or submits a form (Mimic stubs
  # are process-independent — the actions run in the LiveView).
  defp stub_provider do
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    stub(Tailscale, :update_credential, fn _gateway, _key -> :ok end)
    stub(Tailscale, :refresh_routes, fn _gateway -> {:ok, %{}} end)
    stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
    stub(Tailscale, :teardown_gateway, fn _gateway -> :ok end)

    # The attach/detach operations' access-edge limbs (ADR-0040 S2):
    # the panel tests stub the provider, so the operations' own cluster
    # work — the kubeconfig resolution, the access arms, and the policy
    # apply — is stubbed here the same way.
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    stub(FluxVale.Clients.K8s.Resources.Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

    stub(FluxVale.Clients.K8s.Resources.Middleware, :create, fn _kc, _ns, _n, _spec ->
      {:ok, %{}}
    end)

    stub(FluxVale.Clients.K8s.Resources.Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

    stub(FluxVale.Clients.K8s.Resources.NetworkPolicy, :create, fn _kc, _ns, _n, _spec ->
      {:ok, %{}}
    end)

    stub(FluxVale.Clients.K8s.Resources.Ingress, :delete, fn _kc, _ns, _n -> :ok end)
    stub(FluxVale.Clients.K8s.Resources.Middleware, :delete, fn _kc, _ns, _n -> :ok end)

    :ok
  end

  # The setup grant is the org's only balance: drain it to zero and
  # the funded gate goes dark (the shared fixture — the funded-check
  # tests use the same one).
  defp drain_wallet!(org), do: BillingFixtures.drain_wallet!(org)

  # The signup shape: a welcome credit only — positive balance, never
  # paid (no purchase entry). Exactly the org the paid-once gate
  # exists to stop.
  defp welcome_only!(org) do
    {:ok, wallet} = Billing.ensure_wallet(org)
    {:ok, _welcome} = Billing.grant_credits(wallet, 300)
  end

  # ---- API tokens (#483) helpers ----

  # Self-mint through the operation — the same seam the panel rides,
  # so every precondition the tests assert against is action-built.
  defp mint_token!(user, name, scopes) do
    {:ok, %{pat: pat}} = Identity.mint_pat(user, %{user_id: user.id, name: name, scopes: scopes})
    pat
  end

  # ---- Device sign-ins (#362 T3): the approval surface ----

  describe "the device sign-ins section" do
    test "the section renders with its empty line when nothing is pending", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/access")

      assert has_element?(view, "[data-testid='device-sign-ins']")
      assert has_element?(view, "[data-testid='device-sign-ins-empty']")
      assert has_element?(view, "#device-sign-ins")
      refute has_element?(view, "[data-testid='device-sign-in-row']")
    end

    test "a pending sign-in renders its user_code, scopes, client and expiry", %{
      conn: conn
    } do
      {:ok, _row} =
        Identity.mint_device_code(%{client_id: "fluxvale-cli", scopes: ["instances:read"]})

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      row_html = render(element(view, "[data-testid='device-sign-in-row']"))
      assert row_html =~ ~r/[A-HJ-KM-NP-Z2-9]{4}-[A-HJ-KM-NP-Z2-9]{4}/
      assert has_element?(view, "[data-testid='device-user-code']")
      assert has_element?(view, "[data-testid='device-meta']")

      meta = render(element(view, "[data-testid='device-meta']"))
      assert meta =~ "instances:read"
      assert meta =~ "client fluxvale-cli"
      assert meta =~ "expires in"

      assert has_element?(view, "[data-testid='device-approve']")
      assert has_element?(view, "[data-testid='device-deny']")
      refute has_element?(view, "[data-testid='device-sign-ins-empty']")
    end

    test "empty scopes render as full access (OQ #9's first-party shape)", %{
      conn: conn
    } do
      {:ok, _row} = Identity.mint_device_code(%{client_id: "fluxvale-cli", scopes: []})

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      assert render(element(view, "[data-testid='device-meta']")) =~ "all scopes (full access)"
    end

    test "approving binds the row to the clicking user — the poll then mints for them", %{
      conn: conn,
      owner: owner
    } do
      {:ok, row} =
        Identity.mint_device_code(%{client_id: "fluxvale-cli", scopes: ["wallet:read"]})

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      view
      |> element("[data-testid='device-approve']")
      |> render_click()

      # The row approved with the actor as the approver.
      {:ok, approved_row} = DeviceCode.get_by_device_code(row.device_code, authorize?: false)
      assert approved_row.status == :approved
      assert approved_row.user_id == owner.id

      # The list refreshes (the row leaves pending).
      refute has_element?(view, "[data-testid='device-sign-in-row']")
      assert has_element?(view, "[data-testid='device-sign-ins-empty']")

      # The next poll mints the PAT FOR the clicking user.
      assert {:ok, %{pat: pat}} =
               Identity.poll_device_code("fluxvale-cli", approved_row.device_code)

      assert pat.user_id == owner.id
    end

    test "denying the sign-in leaves the row denied", %{conn: conn} do
      {:ok, minted} = Identity.mint_device_code(%{client_id: "fluxvale-cli", scopes: []})

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      view
      |> element("[data-testid='device-deny']")
      |> render_click()

      {:ok, denied_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      assert denied_row.status == :denied
      assert denied_row.user_id == nil

      refute has_element?(view, "[data-testid='device-sign-in-row']")
    end

    test "a stale click (the row handled between render and click) converges without crashing", %{
      conn: conn,
      owner: owner
    } do
      {:ok, minted} = Identity.mint_device_code(%{client_id: "fluxvale-cli", scopes: []})

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      # The row leaves pending underneath the panel.
      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _denied} = DeviceCode.deny(pending_row, actor: owner)

      view
      |> element("[data-testid='device-approve']")
      |> render_click()

      # The stale-view answer: the list refetched, no crash.
      assert has_element?(view, "[data-testid='device-sign-ins-empty']")
      {:ok, after_click} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      assert after_click.status == :denied
    end

    test "a stale DENY click (the row handled between render and click) converges too", %{
      conn: conn,
      owner: owner
    } do
      {:ok, minted} = Identity.mint_device_code(%{client_id: "fluxvale-cli", scopes: []})

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      # The row leaves pending underneath the panel (another tab won).
      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _approved} = DeviceCode.approve(pending_row, actor: owner)

      view
      |> element("[data-testid='device-deny']")
      |> render_click()

      # The deny was a no-op — the row stays approved (the approve won).
      assert has_element?(view, "[data-testid='device-sign-ins-empty']")
      {:ok, after_click} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      assert after_click.status == :approved
      assert after_click.user_id == owner.id
    end
  end

  # ---- API tokens (#483): create, list, revoke the actor's own PATs ----

  describe "the API tokens section" do
    test "the section renders with the create form, the catalog scopes and the empty line", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/access")

      assert has_element?(view, "[data-testid='api-tokens']")
      assert has_element?(view, "#api-token-form-0")
      assert has_element?(view, "[data-testid='api-token-name-input']")
      assert has_element?(view, "[data-testid='api-token-create']")
      assert has_element?(view, "[data-testid='api-tokens-empty']")
      assert has_element?(view, "#api-token-rows")
      refute has_element?(view, "[data-testid='api-token-row']")
      refute has_element?(view, "[data-testid='api-token-reveal']")
    end

    # #484 W5: the quickstart is ONE click from the mint, on both heads
    # — the personal panel and the org Access tab carry the same link
    # (the section renders the actor's own tokens either way).
    test "the section links the agent quickstart one click away, on both heads", %{
      conn: conn,
      org: org
    } do
      for path <- [~p"/settings/access", ~p"/organizations/#{org.slug}/settings/access"] do
        {:ok, view, _html} = live(conn, path)

        link = render(element(view, "[data-testid='api-tokens-agents-link']"))
        assert link =~ ~s(href="/settings/agents")
        assert link =~ "AI agent"
      end
    end

    test "the scope checkboxes render exactly the existing catalog, not a new mechanism", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/access")

      section_html = render(element(view, "[data-testid='api-tokens']"))
      doc = LazyHTML.from_fragment(section_html)

      values =
        doc
        |> LazyHTML.query("input[data-testid='api-token-scope']")
        |> LazyHTML.attribute("value")

      assert Enum.sort(values) == Enum.sort(Scopes.all_scopes())

      # The labels ride the same strings (a catalog addition labels itself).
      section = render(element(view, "[data-testid='api-tokens']"))
      assert section =~ "instances:read"
      assert section =~ "Instances, read only"
      assert section =~ "instances:write"
      assert section =~ "Instances, manage (includes read)"
    end

    test "creating a token shows the raw once, stores hash-only, and never logs it", %{
      conn: conn,
      owner: owner
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/access")

      log =
        capture_log(fn ->
          view
          |> form("#api-token-form-0", %{
            token: %{name: "ci deploys", scopes: ["instances:read", "wallet:read"]}
          })
          |> render_submit()
        end)

      # The raw value exists on the page (the reveal) and nowhere else:
      # not in the logs.
      refute log =~ "fvpat_"

      assert has_element?(view, "[data-testid='api-token-reveal']")
      reveal = render(element(view, "[data-testid='api-token-reveal']"))
      assert reveal =~ "only time the full token is shown"
      assert has_element?(view, "[data-testid='api-token-reveal-copy']")
      assert has_element?(view, "[data-testid='api-token-reveal-done']")

      html = render(view)
      assert [raw] = Regex.run(~r/fvpat_[A-Za-z0-9_-]{43}/, html)

      # The page renders the raw exactly where the reveal needs it: the
      # code line the user reads and the copy button's payload. Nothing
      # else on the page carries it (the copy hook's data attribute is
      # the second rendering — both are the reveal's own nodes).
      occurrences = Regex.scan(~r/fvpat_[A-Za-z0-9_-]{43}/, html)
      assert length(occurrences) == 2
      refute render(element(view, "#api-token-rows")) =~ raw

      # Hash-only storage: the row answers to the digest of the shown
      # value and carries nothing that reproduces it.
      digest = PersonalAccessToken.token_hash(raw)

      assert {:ok, row} = PersonalAccessToken.get_by_token_hash(digest, authorize?: false)
      assert row.token_hash == digest
      assert row.token_hash != raw
      assert row.user_id == owner.id
      assert row.name == "ci deploys"
      assert row.scopes == ["instances:read", "wallet:read"]

      # The list refreshed with the new row.
      row_html = render(element(view, "[data-testid='api-token-row']"))
      assert row_html =~ "ci deploys"
      refute row_html =~ raw

      # The submission is disarmed: the form re-keyed (a changed id
      # replaces the subtree, clearing the dirty input a value patch
      # cannot reach), so a second click cannot mint a duplicate.
      refute has_element?(view, "#api-token-form-0")
      assert has_element?(view, "#api-token-form-1")

      # Dismissal is the end of the raw value's life: nothing renders
      # or holds it afterwards.
      view
      |> element("[data-testid='api-token-reveal-done']")
      |> render_click()

      refute has_element?(view, "[data-testid='api-token-reveal']")
      refute render(view) =~ raw
    end

    test "no scopes selected mints an identity-only token", %{conn: conn, owner: owner} do
      {:ok, view, _html} = live(conn, ~p"/settings/access")

      view
      |> form("#api-token-form-0", %{token: %{name: "me only"}})
      |> render_submit()

      meta = render(element(view, "[data-testid='api-token-meta']"))
      assert meta =~ "no scopes (identity only)"

      assert {:ok, [row]} = PersonalAccessToken.list_for_user(owner.id, authorize?: false)
      assert row.scopes == []
      assert row.name == "me only"
      assert row.user_id == owner.id
    end

    test "the list is newest first when several tokens exist", %{conn: conn, owner: owner} do
      mint_token!(owner, "first", [])
      mint_token!(owner, "second", [])

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      rows_html = render(element(view, "#api-token-rows"))
      doc = LazyHTML.from_fragment(rows_html)

      names =
        doc
        |> LazyHTML.query("[data-testid='api-token-name']")
        |> Enum.map(fn node ->
          name = LazyHTML.text(node)
          String.trim(name)
        end)

      assert names == ["second", "first"]
    end

    test "same-instant rows tie-break by id and the comparator orders mixed inserts", %{
      conn: conn,
      owner: owner
    } do
      # Pinned created_at values are write-time stamps the mint cannot
      # set — the sanctioned Ash.Seed exception. Newest inserted first,
      # two rows sharing an instant: the sort then exercises every arm
      # (the :gt on the newer pair, the :eq tiebreak on the equal pair)
      # that ascending back-to-back mints can never reach.
      now = DateTime.utc_now()
      second_precision_now = DateTime.truncate(now, :second)
      future = DateTime.add(second_precision_now, 365 * 24 * 60 * 60, :second)

      base = %{
        user_id: owner.id,
        scopes: [],
        expires_at: future,
        metadata: %{},
        last_used_at: nil,
        revoked_at: nil
      }

      Ash.Seed.seed!(
        PersonalAccessToken,
        Map.merge(base, %{
          name: "newest",
          token_hash: PersonalAccessToken.token_hash("seed-newest"),
          created_at: DateTime.add(second_precision_now, 60, :second),
          updated_at: DateTime.add(second_precision_now, 60, :second)
        })
      )

      Ash.Seed.seed!(
        PersonalAccessToken,
        Map.merge(base, %{
          name: "tie-a",
          token_hash: PersonalAccessToken.token_hash("seed-tie-a"),
          created_at: second_precision_now,
          updated_at: second_precision_now
        })
      )

      Ash.Seed.seed!(
        PersonalAccessToken,
        Map.merge(base, %{
          name: "tie-b",
          token_hash: PersonalAccessToken.token_hash("seed-tie-b"),
          created_at: second_precision_now,
          updated_at: second_precision_now
        })
      )

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      rows_html = render(element(view, "#api-token-rows"))
      doc = LazyHTML.from_fragment(rows_html)

      names =
        doc
        |> LazyHTML.query("[data-testid='api-token-name']")
        |> Enum.map(fn node ->
          name = LazyHTML.text(node)
          String.trim(name)
        end)

      # "newest" is the chronologically latest row. "tie-a" and
      # "tie-b" share an instant: the later insert carries the bigger
      # uuid_v7 and renders first.
      assert names == ["newest", "tie-b", "tie-a"]
    end

    test "a listed token renders its metadata: scopes, created, last used, expiry", %{
      conn: conn,
      owner: owner
    } do
      pat = mint_token!(owner, "terraform", ["gateways:read"])

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      row = render(element(view, "[data-testid='api-token-row']"))
      assert row =~ "terraform"
      assert row =~ "gateways:read"
      assert row =~ "Created"
      assert row =~ "Never used"
      assert row =~ "Expires"
      assert row =~ Calendar.strftime(pat.expires_at, "%b %d, %Y")
      assert has_element?(view, "[data-testid='api-token-status-active']")
      assert has_element?(view, "[data-testid='api-token-revoke']")
    end

    test "a token the API has been used with shows its last-used date", %{
      conn: conn,
      owner: owner
    } do
      pat = mint_token!(owner, "used", [])

      # The auth path's system write (the plug's touch posture) — no
      # actor-facing surface stamps last-used.
      assert {:ok, _stamped} = PersonalAccessToken.touch_last_used(pat, authorize?: false)

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      assert render(element(view, "[data-testid='api-token-meta']")) =~ "Last used"
    end

    test "an expired token shows the Expired badge and no revoke affordance", %{
      conn: conn,
      owner: owner
    } do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, %{pat: _pat}} =
        Identity.mint_pat(owner, %{user_id: owner.id, name: "stale", scopes: [], expires_at: past})

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      assert has_element?(view, "[data-testid='api-token-status-expired']")
      assert render(element(view, "[data-testid='api-token-row']")) =~ "stale"
      refute has_element?(view, "[data-testid='api-token-revoke']")
    end

    test "revoke is confirm-armed: a crafted click is a no-op, cancel disarms, confirm severs", %{
      conn: conn,
      owner: owner
    } do
      pat = mint_token!(owner, "ci", ["wallet:read"])

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      # Un-armed: the crafted revoke is a no-op, the row stays live.
      render_click(view, "revoke-token", %{"id" => pat.id})
      assert {:ok, row} = PersonalAccessToken.get(pat.id, authorize?: false)
      assert row.revoked_at == nil

      # Arm: the confirm callout replaces the button; cancel disarms.
      view
      |> element("[data-testid='api-token-revoke']")
      |> render_click()

      assert has_element?(view, "[data-testid='api-token-revoke-confirm']")
      refute has_element?(view, "[data-testid='api-token-revoke']")

      view
      |> element("[data-testid='api-token-revoke-cancel']")
      |> render_click()

      refute has_element?(view, "[data-testid='api-token-revoke-confirm']")
      assert has_element?(view, "[data-testid='api-token-revoke']")

      # Arm again and confirm: the sever is immediate.
      view
      |> element("[data-testid='api-token-revoke']")
      |> render_click()

      view
      |> element("[data-testid='api-token-revoke-confirm-button']")
      |> render_click()

      assert has_element?(
               view,
               "#flash-info",
               "Token revoked. Anything using it stops working now."
             )

      assert has_element?(view, "[data-testid='api-token-status-revoked']")
      refute has_element?(view, "[data-testid='api-token-revoke']")

      assert {:ok, severed} = PersonalAccessToken.get(pat.id, authorize?: false)
      refute severed.revoked_at == nil
    end

    test "the panel is self-service: another user's token is neither listed nor revocable", %{
      conn: conn,
      owner: owner
    } do
      pat = mint_token!(owner, "owner only", ["catalog:read"])
      intruder = AccountsFixtures.user!()

      {:ok, view, _html} = live(SessionHelpers.sign_in(conn, intruder), ~p"/settings/access")

      refute render(view) =~ "owner only"
      assert has_element?(view, "[data-testid='api-tokens-empty']")

      # Forged ids arm and revoke — the operation's owner-gated lookup
      # is what refuses, the flash is the honest line.
      render_click(view, "arm-token-revoke", %{"id" => pat.id})
      render_click(view, "revoke-token", %{"id" => pat.id})

      assert has_element?(
               view,
               "#flash-error",
               "Couldn't revoke the token. Refresh and try again."
             )

      assert {:ok, still_live} = PersonalAccessToken.get(pat.id, authorize?: false)
      assert still_live.revoked_at == nil
    end

    test "a device-flow token shows in the list with its provenance and revokes like any other",
         %{
           conn: conn,
           owner: owner
         } do
      {:ok, row} =
        Identity.mint_device_code(%{client_id: "fluxvale-cli", scopes: ["instances:read"]})

      {:ok, approved} = DeviceCode.approve(row, actor: owner)

      assert {:ok, %{pat: pat}} =
               Identity.poll_device_code("fluxvale-cli", approved.device_code)

      {:ok, view, _html} = live(conn, ~p"/settings/access")

      token_row = render(element(view, "[data-testid='api-token-row']"))
      assert token_row =~ "CLI sign-in"
      assert token_row =~ "instances:read"
      assert has_element?(view, "[data-testid='api-token-provenance']")

      view
      |> element("[data-testid='api-token-revoke']")
      |> render_click()

      view
      |> element("[data-testid='api-token-revoke-confirm-button']")
      |> render_click()

      assert {:ok, severed} = PersonalAccessToken.get(pat.id, authorize?: false)
      refute severed.revoked_at == nil
    end

    test "an empty name is refused and creates nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/access")

      view
      |> form("#api-token-form-0", %{token: %{name: "   "}})
      |> render_submit()

      assert has_element?(view, "#flash-error", "Give the token a name first.")
      assert has_element?(view, "[data-testid='api-tokens-empty']")

      # The failed submit kept the form key (the re-key is the success
      # path's disarm — a failure leaves the typed name standing).
      assert has_element?(view, "#api-token-form-0")
      refute has_element?(view, "#api-token-form-1")
    end

    test "a name past the 100-character limit is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/access")

      view
      |> form("#api-token-form-0", %{token: %{name: String.duplicate("a", 101)}})
      |> render_submit()

      assert has_element?(
               view,
               "#flash-error",
               "Couldn't create the token. Check the name and try again."
             )

      assert has_element?(view, "[data-testid='api-tokens-empty']")
    end

    test "a crafted off-catalog scope is refused by the domain", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/access")

      render_click(view, "create-token", %{
        "token" => %{"name" => "forged", "scopes" => ["wallet:write"]}
      })

      assert has_element?(view, "#flash-error", "The scope selection wasn't valid.")
      assert has_element?(view, "[data-testid='api-tokens-empty']")
    end

    test "a crafted duplicate scope is refused by the domain too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/access")

      render_click(view, "create-token", %{
        "token" => %{"name" => "forged", "scopes" => ["wallet:read", "wallet:read"]}
      })

      assert has_element?(view, "#flash-error", "The scope selection wasn't valid.")
      assert has_element?(view, "[data-testid='api-tokens-empty']")
    end

    test "crafted wrong-typed payloads are no-ops, never crashes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/access")

      # A non-map token payload and a non-binary name land the
      # empty-name refusal; a non-binary revoke id falls through the
      # binary-guarded head to the no-op. None of them crash.
      assert render_click(view, "create-token", %{"token" => "junk"}) =~ "API tokens"

      assert render_click(view, "create-token", %{"token" => %{"name" => ["a", "b"]}}) =~
               "API tokens"

      assert render_click(view, "arm-token-revoke", %{"id" => 123}) =~ "API tokens"
      assert render_click(view, "revoke-token", %{"id" => 123}) =~ "API tokens"

      assert has_element?(view, "[data-testid='api-tokens-empty']")
    end

    test "crafted events without payloads are no-ops, never crashes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/access")

      assert render_click(view, "create-token", %{}) =~ "API tokens"
      assert render_click(view, "arm-token-revoke", %{}) =~ "API tokens"
      assert render_click(view, "revoke-token", %{}) =~ "API tokens"
      assert has_element?(view, "[data-testid='api-tokens-empty']")
    end
  end
end
