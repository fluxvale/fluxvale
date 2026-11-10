defmodule FluxValeWeb.AdminGatewayDetailLiveTest do
  @moduledoc false

  # The gateway detail surface (#501, #613): the gateway's facts, the
  # credential references rendered as NAMES (never keys), and the org's
  # domains with their verification vocabulary plus each row's tailnet
  # claim. Reads carry the platform-admin arm, so a stranger org's
  # gateway renders here too — the missing arm is a missing row. The
  # provider and the Certificate leg are Mimic-stubbed (the fixtures'
  # contract); the route gates ride the shared live_session's arms.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.Clients.K8s
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
    stub(Tailscale, :teardown_gateway, fn _gateway -> :ok end)
    stub(Tailscale, :unclaim_domain, fn _gateway, _domain -> :ok end)

    # The custom-domain registration's Certificate leg (ADR-0040 S1):
    # the platform-side stubs, not a live cluster (the access_domain
    # changes tests' exact stub set).
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)
    stub(Kubereq, :attach, fn req, _opts -> req end)

    stub(Kubereq, :apply, fn _req, manifest, _fm ->
      {:ok, %{status: 201, body: manifest}}
    end)

    admin =
      User.create!(
        "admin-gwdetail-admin-#{@n}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin), bare_conn: conn}
  end

  # A member org (the admin is inside) with its gateway: the row shape
  # the member arm admits onto the page — with #613 the admin arm
  # admits stranger rows just as well (the cross-org test below).
  defp member_gateway!(admin, opts \\ []) do
    {org, _owner} = BillingFixtures.grant_free_org!()

    Membership.create!(%{organization_id: org.id, user_id: admin.id, role: :member},
      authorize?: false
    )

    gateway = AccessFixtures.gateway!(org, Keyword.take(opts, [:state]))

    # The fixture's activate leaves provisioned_at unset (the observer
    # owns the stamp in production); the detail's provisioned line needs
    # the fact, and the funnel accepts it.
    stamped =
      gateway
      |> Ash.Changeset.for_update(
        :update_state,
        %{provisioned_at: DateTime.utc_now()},
        authorize?: false
      )
      |> Ash.update!()

    {org, stamped}
  end

  # The org's platform domain row — system-minted through the system
  # action (the instance-create path's seam), born :verified.
  defp platform_domain!(org) do
    AccessDomain.mint_platform!(
      %{domain: "fluxvale.lvh.me", organization_id: org.id},
      authorize?: false
    )
  end

  # A :custom domain through the REGISTER action (the entitlement gates
  # are the policy's own: membership plus a paid-once funded wallet),
  # landing :pending — then any state the funnels promote to.
  defp custom_domain!(admin, org, state) do
    BillingFixtures.funded_wallet!(org: org)
    BillingFixtures.mark_paid!(org)

    {:ok, domain} =
      AccessDomain.register(
        %{
          domain: "apps.customer-#{System.unique_integer([:positive])}.com",
          organization_id: org.id
        },
        actor: admin
      )

    case state do
      :pending ->
        domain

      :verified ->
        Ash.update!(domain, %{cert_secret_ref: "cert-secret"},
          action: :mark_verified,
          authorize?: false
        )

      :failed ->
        Ash.update!(domain, %{}, action: :mark_failed, authorize?: false)

      :needs_attention ->
        Ash.update!(domain, %{}, action: :mark_needs_attention, authorize?: false)

      :suspended ->
        verified =
          Ash.update!(domain, %{cert_secret_ref: "cert-secret"},
            action: :mark_verified,
            authorize?: false
          )

        Ash.update!(verified, %{}, action: :mark_suspended, authorize?: false)
    end
  end

  defp attribute(view, testid, name) do
    html = render(element(view, "[data-testid='#{testid}']"))
    document = LazyHTML.from_fragment(html)
    matches = LazyHTML.query(document, "[data-testid='#{testid}']")
    first = Enum.at(matches, 0)
    values = LazyHTML.attribute(first, name) || []

    Enum.join(values, "")
  end

  defp text_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  describe "the gateway facts" do
    test "render the product's vocabulary and the identifier grammar", %{
      conn: conn,
      admin: admin
    } do
      {org, gateway} = member_gateway!(admin, state: :active)

      {:ok, view, _html} = live(conn, "/admin/gateways/#{gateway.id}")

      assert has_element?(view, "[data-testid='admin-gateways-detail']")
      assert text_of(view, "[data-testid='admin-gateways-detail-state']") == "Connected"
      assert text_of(view, "[data-testid='admin-gateways-detail-hostname']") == gateway.hostname

      assert text_of(view, "[data-testid='admin-gateways-detail-tailnet']") ==
               gateway.tailnet_domain

      assert text_of(view, "[data-testid='admin-gateways-detail-provider']") == "Tailscale"
      assert text_of(view, "[data-testid='admin-gateways-detail-rate']") =~ "$2.00"

      assert text_of(view, "[data-testid='admin-gateways-detail-rate']") =~
               "Suspended or removed, nothing accrues"

      provisioned = Calendar.strftime(gateway.provisioned_at, "%b %d, %Y")
      assert text_of(view, "[data-testid='admin-gateways-detail-provisioned']") =~ provisioned

      created = Calendar.strftime(gateway.created_at, "%b %d, %Y")
      assert text_of(view, "[data-testid='admin-gateways-detail-created']") =~ created

      assert has_element?(view, "[data-testid='admin-gateways-back-link']")
      assert render(view) =~ org.name

      # A bare "Connected" message under a Connected pill is a stray
      # echo — the row's words render only for the informative states.
      refute has_element?(view, "[data-testid='admin-gateways-detail-status-message']")
    end

    test "an attention state renders its honest word, the row's copy, and the shape cue", %{
      conn: conn,
      admin: admin
    } do
      {_org, gateway} = member_gateway!(admin, state: :needs_attention)

      {:ok, view, _html} = live(conn, "/admin/gateways/#{gateway.id}")

      assert text_of(view, "[data-testid='admin-gateways-detail-state']") == "Needs attention"

      # One label, one shape per section: the gateway's Needs attention
      # carries the same triangle its domain namesake does.
      assert has_element?(
               view,
               "[data-testid='admin-gateways-detail-state'] .hero-exclamation-triangle"
             )

      assert has_element?(view, "[data-testid='admin-gateways-detail-status-message']")
    end

    test "a Connecting gateway moves on its own icon, not the shared amber dot", %{
      conn: conn,
      admin: admin
    } do
      {_org, gateway} = member_gateway!(admin, state: :provisioning)

      {:ok, view, _html} = live(conn, "/admin/gateways/#{gateway.id}")

      assert text_of(view, "[data-testid='admin-gateways-detail-state']") == "Connecting"
      assert has_element?(view, "[data-testid='admin-gateways-detail-state'] .hero-bolt")
    end

    test "an attention row carries its clock; a stale stamp under another state carries none",
         %{conn: conn, admin: admin} do
      {_org, flagged} = member_gateway!(admin, state: :needs_attention)

      clocked =
        flagged
        |> Ash.Changeset.for_update(
          :update_state,
          %{needs_attention_since: DateTime.add(DateTime.utc_now(), -2, :day)},
          authorize?: false
        )
        |> Ash.update!()

      # The stale-stamp shape: Suspend never clears the stamp, so the
      # clock must key on the STATE (the list pin's discipline) — a
      # suspended row shows no clock however old its anchor is.
      {_stale_org, active} = member_gateway!(admin, state: :active)

      stale =
        active
        |> Ash.Changeset.for_update(
          :update_state,
          %{state: :suspended, needs_attention_since: DateTime.add(DateTime.utc_now(), -1, :day)},
          authorize?: false
        )
        |> Ash.update!()

      {:ok, view, _html} = live(conn, "/admin/gateways/#{clocked.id}")

      since = Calendar.strftime(clocked.needs_attention_since, "%b %d, %Y")

      assert text_of(view, "[data-testid='admin-gateways-detail-attention-since']") =~ since

      {:ok, stale_view, _html} = live(conn, "/admin/gateways/#{stale.id}")

      refute has_element?(stale_view, "[data-testid='admin-gateways-detail-attention-since']")
    end
  end

  describe "the credential references" do
    test "render as names, under copy that keeps them honest", %{conn: conn, admin: admin} do
      {_org, gateway} = member_gateway!(admin, state: :active)

      # The token ref rides the system funnel (the claiming system's
      # write, ADR-0040 §5) — the only writer.
      claimed =
        AccessGateway.set_api_token_ref!(
          gateway,
          %{api_token_secret_ref: "api-token-stub"},
          authorize?: false
        )

      {:ok, view, _html} = live(conn, "/admin/gateways/#{claimed.id}")

      assert has_element?(view, "[data-testid='admin-gateways-secret-card']")

      assert text_of(view, "[data-testid='admin-gateways-secret-credential-ref']") ==
               "credential-stub"

      assert text_of(view, "[data-testid='admin-gateways-secret-token-ref']") == "api-token-stub"

      # THE sentence: names, never keys. The copy says it, and the
      # auth key the fixture pasted appears nowhere on the page.
      assert has_element?(
               view,
               "[data-testid='admin-gateways-secret-card']",
               "never pass through this console"
             )

      refute render(view) =~ "tskey-test"
    end

    test "a nil API token entry reads as exactly what the card knows", %{conn: conn, admin: admin} do
      {_org, gateway} = member_gateway!(admin)

      {:ok, view, _html} = live(conn, "/admin/gateways/#{gateway.id}")

      # A nil ref means only that nothing is recorded: the claim path
      # reads the Secret by its derived name, so a usable Secret can
      # exist without a ref on the row — no inference about claims.
      assert text_of(view, "[data-testid='admin-gateways-secret-token-none']") == "Not recorded."

      refute has_element?(view, "[data-testid='admin-gateways-secret-token-ref']")
    end

    test "a stamped token carries the key-age signal — the 90-day rotation clock", %{
      conn: conn,
      admin: admin
    } do
      {_org, gateway} = member_gateway!(admin)

      # The ref write stamps token_set_at (its change, ADR-0040 §5) —
      # the only writer, so the page reads the funnel's own fact.
      stamped =
        AccessGateway.set_api_token_ref!(
          gateway,
          %{api_token_secret_ref: "api-token-stub"},
          authorize?: false
        )

      {:ok, view, _html} = live(conn, "/admin/gateways/#{stamped.id}")

      stamp = Calendar.strftime(stamped.token_set_at, "%b %d, %Y")

      assert text_of(view, "[data-testid='admin-gateways-secret-token-set']") =~ stamp
      assert text_of(view, "[data-testid='admin-gateways-secret-token-set']") =~ "90 days"
    end

    test "a row with no recorded credential entry says so instead of showing nil", %{
      conn: conn,
      admin: admin
    } do
      {_org, gateway} = member_gateway!(admin)

      # A nil credential ref is a state the create cannot produce (the
      # provider's provision leg writes it synchronously), and the
      # fixture's returned struct predates that write — so the row is
      # re-read before the forced clear. The :update_state funnel
      # carries the column; the system seam is the honest writer.
      row =
        AccessGateway
        |> Ash.Query.for_read(:get_by_id, %{id: gateway.id}, authorize?: false)
        |> Ash.read!()
        |> Enum.at(0)

      cleared =
        row
        |> Ash.Changeset.for_update(:update_state, %{}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:credential_secret_ref, nil)
        |> Ash.update!()

      {:ok, view, _html} = live(conn, "/admin/gateways/#{cleared.id}")

      assert text_of(view, "[data-testid='admin-gateways-secret-credential-ref']") ==
               "Not recorded."
    end
  end

  describe "the org's domains" do
    test "render every state with its honest vocabulary", %{conn: conn, admin: admin} do
      {org, gateway} = member_gateway!(admin, state: :active)

      platform = platform_domain!(org)
      pending = custom_domain!(admin, org, :pending)
      verified = custom_domain!(admin, org, :verified)
      failed = custom_domain!(admin, org, :failed)
      attention = custom_domain!(admin, org, :needs_attention)
      suspended = custom_domain!(admin, org, :suspended)

      {:ok, view, _html} = live(conn, "/admin/gateways/#{gateway.id}")

      # The kinds: system-minted vs the owner's registration.
      assert text_of(view, "[data-testid='admin-gateways-domain-kind-#{platform.id}']") ==
               "Platform"

      assert text_of(view, "[data-testid='admin-gateways-domain-kind-#{verified.id}']") ==
               "Custom"

      # The verification vocabulary, never the raw atoms.
      assert text_of(view, "[data-testid='admin-gateways-domain-state-#{platform.id}']") ==
               "Verified"

      assert text_of(view, "[data-testid='admin-gateways-domain-state-#{pending.id}']") ==
               "Pending"

      assert text_of(view, "[data-testid='admin-gateways-domain-state-#{verified.id}']") ==
               "Verified"

      assert text_of(view, "[data-testid='admin-gateways-domain-state-#{failed.id}']") == "Failed"

      assert text_of(view, "[data-testid='admin-gateways-domain-state-#{attention.id}']") ==
               "Needs attention"

      assert text_of(view, "[data-testid='admin-gateways-domain-state-#{suspended.id}']") ==
               "Suspended"

      # The shape cues, one per state (the review's grammar): the
      # triangle and the pause match their gateway namesakes.
      assert has_element?(
               view,
               "[data-testid='admin-gateways-domain-state-#{verified.id}'] .hero-check-circle"
             )

      assert has_element?(
               view,
               "[data-testid='admin-gateways-domain-state-#{failed.id}'] .hero-x-mark"
             )

      assert has_element?(
               view,
               "[data-testid='admin-gateways-domain-state-#{attention.id}'] .hero-exclamation-triangle"
             )

      assert has_element?(
               view,
               "[data-testid='admin-gateways-domain-state-#{suspended.id}'] .hero-pause"
             )

      # The pulse is the non-color half of the in-flight state.
      assert render(element(view, "[data-testid='admin-gateways-domain-state-#{pending.id}']")) =~
               "animate-pulse"

      registered = Calendar.strftime(verified.registered_at, "%b %d, %Y")

      assert text_of(view, "[data-testid='admin-gateways-domain-registered-#{verified.id}']") ==
               registered
    end

    test "real pagination replaces the old cap: page two carries the oldest domain", %{
      conn: conn,
      admin: admin
    } do
      {org, gateway} = member_gateway!(admin)

      # The platform row is minted first, so it is the oldest row the
      # page boundary pushes off page one.
      platform = platform_domain!(org)

      for _n <- 1..25 do
        custom_domain!(admin, org, :pending)
      end

      {:ok, view, _html} = live(conn, "/admin/gateways/#{gateway.id}?size=25")

      # A full first page (newest registered first), the platform row
      # waiting on page two. The count copy carries the honest total.
      assert has_element?(
               view,
               "[data-testid='admin-gateways-domains-table-count']",
               "1 to 25 of 26"
             )

      refute has_element?(view, "[data-testid='admin-gateways-domain-name-#{platform.id}']")

      view
      |> element("[data-testid='admin-gateways-domains-table-page-next']")
      |> render_click()

      assert has_element?(view, "[data-testid='admin-gateways-domain-name-#{platform.id}']")

      assert has_element?(
               view,
               "[data-testid='admin-gateways-domains-table-page-label']",
               "Page 2 of 2"
             )

      # The canonical URL omits the default size: page 2 alone states
      # the view.
      assert_patched(view, "/admin/gateways/#{gateway.id}?page=2")

      # The table's guard rails: a crafted event is a no-op (the view
      # is unmoved), and a whitelisted sort rides the URL.
      render_click(view, "sort", %{"field" => "not-a-field"})
      render_click(view, "page", %{"nav" => "sideways"})
      render_click(view, "sort", %{})
      render_click(view, "page", %{})
      render_click(view, "size", %{})
      render_click(view, "size", %{"size" => "999"})

      assert has_element?(view, "[data-testid='admin-gateways-domains-table-page-label']")

      {:ok, sorted, _html} = live(conn, "/admin/gateways/#{gateway.id}?sort=domain&dir=asc")

      assert has_element?(sorted, "[data-testid='admin-gateways-domains-table-header-domain']")
    end

    test "an org with no domains gets the honest empty state", %{conn: conn, admin: admin} do
      {_org, gateway} = member_gateway!(admin)

      {:ok, view, _html} = live(conn, "/admin/gateways/#{gateway.id}")

      assert has_element?(view, "[data-testid='admin-gateways-domains-empty']")
      refute has_element?(view, "[data-testid^='admin-gateways-domain-name-']")
    end

    test "each domain carries its tailnet claim — a fact apart from the state badge", %{
      conn: conn,
      admin: admin
    } do
      {org, gateway} = member_gateway!(admin, state: :active)

      unclaimed = custom_domain!(admin, org, :verified)
      claimed = custom_domain!(admin, org, :verified)

      # The claims map rides the claims funnel (the claim/unclaim
      # operations' writer): only `claimed`'s domain is on the tailnet.
      gateway
      |> Ash.Changeset.for_update(
        :update_claims,
        %{
          dns_claims: %{
            claimed.domain => %{"ip" => "100.100.100.1", "tailnet" => "example.ts.net"}
          }
        },
        authorize?: false
      )
      |> Ash.update!()

      {:ok, view, _html} = live(conn, "/admin/gateways/#{gateway.id}")

      # Both rows are :verified (cert issuance) — the claim line is
      # what differs, and it differs per row.
      assert text_of(view, "[data-testid='admin-gateways-domain-state-#{unclaimed.id}']") ==
               "Verified"

      assert text_of(view, "[data-testid='admin-gateways-domain-state-#{claimed.id}']") ==
               "Verified"

      assert has_element?(
               view,
               "[data-testid='admin-gateways-domain-claim-#{claimed.id}']",
               "Claimed on the tailnet"
             )

      assert has_element?(
               view,
               "[data-testid='admin-gateways-domain-unclaimed-#{unclaimed.id}']",
               "Not on the tailnet"
             )
    end
  end

  describe "the missing arm" do
    test "an unknown id bounces back with the plain not-here flash", %{conn: conn} do
      missing_id = "00000000-0000-0000-0000-000000000000"

      assert {:error, {:live_redirect, %{to: "/admin/gateways", flash: flash}}} =
               live(conn, "/admin/gateways/#{missing_id}")

      # The filter-less admin read makes an empty answer "no such row"
      # — the same plain sentence the typo arm carries, no scope
      # verdict left to guess (#613).
      assert flash["error"] == "That gateway does not exist."
      refute Map.has_key?(flash, "info")
    end

    test "a malformed id takes the same plain arm", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/gateways", flash: flash}}} =
               live(conn, "/admin/gateways/not-a-uuid")

      assert flash["error"] == "That gateway does not exist."
      refute Map.has_key?(flash, "info")
    end

    test "a stranger org's gateway renders — the blanket reads cross-org (#644), with the operator-truth fields",
         %{conn: conn} do
      {stranger_org, gateway} = stranger_gateway!()

      # The clock and the token stamp ride the system funnels (the
      # only writers), so the cross-org page proves the whole #613
      # surface: the row, the clock, the key age.
      flagged =
        gateway
        |> Ash.Changeset.for_update(
          :update_state,
          %{
            state: :needs_attention,
            needs_attention_since: DateTime.add(DateTime.utc_now(), -3, :day)
          },
          authorize?: false
        )
        |> Ash.update!()
        |> AccessGateway.set_api_token_ref!(%{api_token_secret_ref: "tok-stub"},
          authorize?: false
        )

      {:ok, view, _html} = live(conn, "/admin/gateways/#{flagged.id}")

      assert has_element?(view, "[data-testid='admin-gateways-detail']")
      assert render(view) =~ stranger_org.name

      assert has_element?(view, "[data-testid='admin-gateways-detail-attention-since']")
      assert has_element?(view, "[data-testid='admin-gateways-secret-token-set']")
    end
  end

  # A stranger org's gateway — a fresh org whose only member is its
  # owner, the exact shape #613's arm admits cross-org.
  defp stranger_gateway! do
    {org, _owner} = BillingFixtures.grant_free_org!()
    gateway = AccessFixtures.gateway!(org)
    {org, gateway}
  end

  describe "the domains controls" do
    test "executes every control, and the floor and scroll wrapper hold", %{
      conn: conn,
      admin: admin
    } do
      {org, gateway} = member_gateway!(admin)
      platform_domain!(org)

      for _n <- 1..25 do
        custom_domain!(admin, org, :pending)
      end

      {:ok, view, _html} = live(conn, "/admin/gateways/#{gateway.id}")

      # The floor and the internal scroll ride the component: the
      # table region carries the computed min-width and the overflow
      # wrapper never leaves (finding 8's regression guard).
      html = render(view)

      assert html =~ "min-width:"
      assert html =~ "overflow-x-auto"

      # Sort ascending, then the sorted column flips to descending.
      view
      |> element("[data-testid='admin-gateways-domains-table-sort-domain']")
      |> render_click()

      assert attribute(view, "admin-gateways-domains-table-header-domain", "aria-sort") ==
               "ascending"

      view
      |> element("[data-testid='admin-gateways-domains-table-sort-domain']")
      |> render_click()

      assert attribute(view, "admin-gateways-domains-table-header-domain", "aria-sort") ==
               "descending"

      # Prev: page two, then back to one.
      view
      |> element("[data-testid='admin-gateways-domains-table-page-next']")
      |> render_click()

      view
      |> element("[data-testid='admin-gateways-domains-table-page-prev']")
      |> render_click()

      assert text_of(view, "[data-testid='admin-gateways-domains-table-page-label']") =~
               "Page 1 of"

      # Every size option executes.
      view
      |> element("[data-testid='admin-gateways-domains-table-size-50']")
      |> render_click()

      assert has_element?(
               view,
               "[data-testid='admin-gateways-domains-table-size-50'][aria-pressed=true]"
             )

      view
      |> element("[data-testid='admin-gateways-domains-table-size-100']")
      |> render_click()

      assert has_element?(
               view,
               "[data-testid='admin-gateways-domains-table-size-100'][aria-pressed=true]"
             )

      view
      |> element("[data-testid='admin-gateways-domains-table-size-25']")
      |> render_click()

      assert has_element?(
               view,
               "[data-testid='admin-gateways-domains-table-size-25'][aria-pressed=true]"
             )

      # The deep-link clamp: a crafted page answers with the last one.
      {:ok, clamped, _html} = live(conn, "/admin/gateways/#{gateway.id}?page=10000")

      assert text_of(clamped, "[data-testid='admin-gateways-domains-table-page-label']") =~
               "Page 2 of 2"
    end
  end

  describe "the gates" do
    test "anonymous bounces to /sign-in", %{bare_conn: conn} do
      conn = get(conn, "/admin/gateways/00000000-0000-0000-0000-000000000000")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "a signed-in non-admin gets a bare 403", %{bare_conn: conn} do
      user = SessionHelpers.user!()
      signed = SessionHelpers.sign_in(conn, user)
      conn = get(signed, "/admin/gateways/00000000-0000-0000-0000-000000000000")

      assert conn.status == 403
    end
  end
end
