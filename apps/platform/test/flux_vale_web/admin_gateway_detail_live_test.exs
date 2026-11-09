defmodule FluxValeWeb.AdminGatewayDetailLiveTest do
  @moduledoc false

  # The gateway detail surface (#501): the gateway's facts, the
  # credential references rendered as NAMES (never keys), and the org's
  # domains with their verification vocabulary. The read that lands
  # here is members-only, so a non-member admin's id takes the same
  # honest arm as an unknown one. The provider and the Certificate leg
  # are Mimic-stubbed (the fixtures' contract); the route gates ride
  # the shared live_session's arms.

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

  require Ash.Query

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

  # A member org (the admin is inside) with its gateway: the only shape
  # the members-only reads admit onto the page.
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
    end

    test "an org with no domains gets the honest empty state", %{conn: conn, admin: admin} do
      {_org, gateway} = member_gateway!(admin)

      {:ok, view, _html} = live(conn, "/admin/gateways/#{gateway.id}")

      assert has_element?(view, "[data-testid='admin-gateways-domains-empty']")
      refute has_element?(view, "[data-testid^='admin-gateways-domain-name-']")
    end
  end

  describe "the missing arm" do
    test "an unknown id bounces back with the member-scope flash copy", %{conn: conn} do
      missing_id = "00000000-0000-0000-0000-000000000000"

      assert {:error, {:live_redirect, %{to: "/admin/gateways", flash: flash}}} =
               live(conn, "/admin/gateways/#{missing_id}")

      assert flash["info"] =~ "That gateway is not listed"
      assert flash["info"] =~ "member-scoped"
    end

    test "a malformed id takes the plain typo arm, no authorization cause", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/gateways", flash: flash}}} =
               live(conn, "/admin/gateways/not-a-uuid")

      # A typo gets the sibling's plain answer — presenting the
      # member-scope sentence here would read as an authorization
      # verdict on a mistyped id.
      assert flash["error"] == "That gateway does not exist."
      refute Map.has_key?(flash, "info")
    end

    test "a stranger org's gateway detail renders — the blanket widened the read (#644)",
         %{
           conn: conn,
           admin: admin
         } do
      {_stranger_org, hidden} =
        member_gateway_unreachable!(admin)

      {:ok, view, _html} = live(conn, "/admin/gateways/#{hidden.id}")

      # ADR-0047: platform-admin reads are cross-org by construction —
      # the member filter no longer hides a foreign gateway's detail.
      assert has_element?(view, "[data-testid='admin-gateways-detail']")
      assert has_element?(view, "[data-testid='admin-gateways-detail-state']")
    end
  end

  # A NON-member org's gateway: unreachable for member-shaped reads —
  # the fixture shape the widened-admin tests above read across.
  defp member_gateway_unreachable!(admin) do
    {org, _owner} = BillingFixtures.grant_free_org!()

    gateway = AccessFixtures.gateway!(org)

    refute Membership
           |> Ash.Query.filter(organization_id == ^org.id and user_id == ^admin.id)
           |> Ash.exists?(actor: admin)

    {org, gateway}
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
