defmodule FluxValeWeb.OrganizationLive.AccessTest do
  @moduledoc false

  # The Access tab's gateway panel (#273, ADR-0039): the lifecycle
  # through the actions, the provider Mimic-stubbed (the cluster is the
  # provider's subject — the AccessGateway changes tests own it).

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import FluxVale.TestSupport.NoK8sLeaks
  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.Billing
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  setup %{conn: conn} do
    owner = AccountsFixtures.user!()
    # The JIT welcome grant funds the personal org — the precondition
    # the create/resume funded gates read. Unfunded tests drain it.
    org = AccountsFixtures.personal_org!(owner)

    {:ok, conn: SessionHelpers.sign_in(conn, owner), owner: owner, org: org}
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
      assert has_element?(view, "input[type='password']")

      # Funded by the JIT welcome grant: no top-up hint. And no card —
      # nothing is provisioned yet.
      refute has_element?(view, "[data-testid='access-prefund-hint']")
      refute has_element?(view, "[data-testid='access-gateway-card']")

      refute_k8s_terms(render(view))
    end

    test "the tab nav marks Access current on this page", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      access_tab = render(element(view, "[data-testid='org-settings-tab-access']"))
      assert access_tab =~ ~s(aria-current="page")
      assert access_tab =~ "border-primary"

      general_tab = render(element(view, "[data-testid='org-settings-tab-general']"))
      refute general_tab =~ "border-primary"
    end

    test "an unfunded org sees the top-up hint before submitting", %{conn: conn, org: org} do
      drain_wallet!(org)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid='access-prefund-hint']")
      assert has_element?(view, "[data-testid='access-prefund-link']")
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

  describe "enabling private access" do
    test "a funded org's key lands a connecting gateway at the config price", %{
      conn: conn,
      owner: owner,
      org: org
    } do
      stub_provider()

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> form("#access-enable-form", gateway: %{auth_key: "tskey-auth-abc123"})
      |> render_submit()

      assert has_element?(view, "[data-testid='access-gateway-card']")
      assert has_element?(view, "[data-testid=status-badge]", "Connecting")
      assert has_element?(view, "[data-testid='access-connecting-note']")
      assert has_element?(view, "[data-testid='access-hostname']")
      refute has_element?(view, "[data-testid='access-empty']")

      {:ok, gateway} = AccessGateway.get_for_organization(org.id, actor: owner)

      assert gateway.hostname =~ ~r/\Afv-[0-9a-f]{8}\z/

      # The row snapshots the panel's price — the same number the empty
      # state displayed.
      assert gateway.monthly_cents ==
               Application.fetch_env!(:flux_vale, :access_gateway)[:monthly_cents]
    end

    test "typing a key validates without creating anything", %{conn: conn, org: org} do
      stub_provider()

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> form("#access-enable-form", gateway: %{auth_key: "tskey-auth-typing"})
      |> render_change()

      assert has_element?(view, "#access-enable-form")
      refute has_element?(view, "[data-testid='access-gateway-card']")

      assert {:error, _none} = AccessGateway.get_for_organization(org.id, authorize?: false)
    end

    test "an unfunded org's enable attempt answers with the top-up copy", %{
      conn: conn,
      org: org
    } do
      drain_wallet!(org)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> form("#access-enable-form", gateway: %{auth_key: "tskey-auth-abc123"})
      |> render_submit()

      assert has_element?(view, "#flash-error", "Top up before enabling private access")

      # The policy gate answered before any work ran: no row exists.
      assert {:error, _none} = AccessGateway.get_for_organization(org.id, authorize?: false)
    end

    test "a failed provisioning re-renders the form and leaves no row", %{conn: conn, org: org} do
      stub_provider()

      expect(Tailscale, :provision_gateway, fn _gateway, _key -> {:error, :cluster_down} end)
      stub(Tailscale, :cleanup_failed_provision, fn _gateway -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> form("#access-enable-form", gateway: %{auth_key: "tskey-auth-abc123"})
      |> render_submit()

      assert has_element?(view, "#access-enable-form")
      refute has_element?(view, "[data-testid='access-gateway-card']")

      # A failed create rolls the row back — the owner's retry is the
      # same form.
      assert {:error, _none} = AccessGateway.get_for_organization(org.id, authorize?: false)
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

    test ":provisioning — the connecting note and no actions", %{conn: conn, org: org} do
      AccessFixtures.gateway!(org, state: :provisioning)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid=status-badge]", "Connecting")
      assert has_element?(view, "[data-testid='access-connecting-note']")

      # Nothing to do yet: no re-paste, no remove.
      refute has_element?(view, "[data-testid='access-repaste']")
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
      assert has_element?(view, "[data-testid='access-suspended-banner']", "the balance ran out")
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

    test ":destroying — the removing note and no actions", %{conn: conn, org: org} do
      AccessFixtures.gateway!(org, state: :destroying)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      assert has_element?(view, "[data-testid=status-badge]", "Removing")
      assert has_element?(view, "[data-testid='access-removing-note']")
      refute has_element?(view, "[data-testid='access-remove']")
      refute has_element?(view, "[data-testid='access-repaste']")
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
      |> form("#access-repaste-form", gateway: %{auth_key: "tskey-auth-typing"})
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
      |> form("#access-repaste-form", gateway: %{auth_key: "tskey-auth-fresh"})
      |> render_submit()

      assert has_element?(view, "[data-testid=status-badge]", "Connecting")

      # The row left :needs_attention for :provisioning — the observed
      # write settles it from there.
      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).state == :provisioning
      assert {:ok, _still_there} = AccessGateway.get_for_organization(org.id, actor: owner)
    end

    test "a failed re-paste keeps the state and the form", %{conn: conn, org: org} do
      gateway = AccessFixtures.gateway!(org, state: :needs_attention)

      expect(Tailscale, :update_credential, fn _gateway, _key -> {:error, :cluster_down} end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> form("#access-repaste-form", gateway: %{auth_key: "tskey-auth-fresh"})
      |> render_submit()

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
  end

  # The gateway lifecycle's provider legs, Mimic-stubbed for every test
  # that mounts the panel with a fixture or submits a form (Mimic stubs
  # are process-independent — the actions run in the LiveView).
  defp stub_provider do
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    stub(Tailscale, :update_credential, fn _gateway, _key -> :ok end)
    stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
    stub(Tailscale, :teardown_gateway, fn _gateway -> :ok end)

    :ok
  end

  # The welcome grant is the org's only balance: debit it to zero (the
  # ledger's unit is micro-cents) and the funded gate goes dark. The
  # same drain the funded-check tests use.
  defp drain_wallet!(org) do
    {:ok, wallet} = Billing.ensure_wallet(org)
    {:ok, loaded} = Ash.load(wallet, :balance, authorize?: false)

    {:ok, _drain} = Billing.debit_wallet(wallet, (loaded.balance || 0) * 10_000)

    :ok
  end
end
