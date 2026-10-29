defmodule FluxValeWeb.OrganizationLive.AccessTest do
  @moduledoc false

  # The Access tab's gateway panel (#273, ADR-0039): the lifecycle
  # through the actions, the provider Mimic-stubbed (the cluster is the
  # provider's subject — the AccessGateway changes tests own it).

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import FluxVale.TestSupport.NoK8sLeaks
  import Phoenix.LiveViewTest

  alias Ash.Error.Changes.StaleRecord
  alias Ash.Error.Invalid
  alias FluxVale.Accounts.Membership
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

      # No row: the policy gate answered before any work ran.
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

      # The failure is a flash, never a silent dead click.
      assert has_element?(view, "#flash-error", "Couldn't enable private access")
      assert has_element?(view, "#access-enable-form")
      refute has_element?(view, "[data-testid='access-gateway-card']")

      # A failed create rolls the row back — the owner's retry is the
      # same form.
      assert {:error, _none} = AccessGateway.get_for_organization(org.id, authorize?: false)
    end

    test "the typed key never echoes into the markup", %{conn: conn, org: org} do
      stub_provider()

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      # The validate round-trip is a read-back if the value re-renders
      # (ADR-0039 §4): the typed marker must not appear in the patch or
      # the markup.
      view
      |> form("#access-enable-form", gateway: %{auth_key: "tskey-TYPING-marker"})
      |> render_change()

      refute render(view) =~ "tskey-TYPING-marker"

      # Typing still works: a submit right after lands the gateway.
      view
      |> form("#access-enable-form", gateway: %{auth_key: "tskey-auth-final"})
      |> render_submit()

      assert has_element?(view, "[data-testid='access-gateway-card']")
    end

    test "a failed re-paste leaves no key echo in the markup", %{conn: conn, org: org} do
      stub_provider()

      AccessFixtures.gateway!(org, state: :needs_attention)

      expect(Tailscale, :update_credential, fn _gateway, _key -> {:error, :cluster_down} end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings/access")

      view
      |> form("#access-repaste-form", gateway: %{auth_key: "tskey-SECRET-marker"})
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
               "if it sticks, reconnect with your key"
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
      |> form("#access-repaste-form", gateway: %{auth_key: "tskey-auth-typing"})
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
               "try connecting again"
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

      # Attached row: name, live address (hostname + port + the owner's
      # tailnet placeholder — the platform cannot know the suffix), and
      # the no-confirm Detach with its reversible-consequence copy.
      assert has_element?(view, "[data-testid='access-attached-row']", attached_instance.name)
      assert has_element?(view, "[data-testid='access-attached-address']", gateway.hostname)
      assert has_element?(view, "[data-testid='access-attached-address']", "8443")
      assert has_element?(view, "[data-testid='access-attached-address']", "your-tailnet")
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

      assert has_element?(view, "[data-testid='access-attach-error']", "wait for Connected")
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

      assert has_element?(view, "#flash-info", "reachable from the panel only again")
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

      assert has_element?(view, "#flash-info", "its public address still works")
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
               "reconnect with a fresh key"
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
    stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
    stub(Tailscale, :teardown_gateway, fn _gateway -> :ok end)

    :ok
  end

  # The welcome grant is the org's only balance: drain it to zero and
  # the funded gate goes dark (the shared fixture — the funded-check
  # tests use the same one).
  defp drain_wallet!(org), do: BillingFixtures.drain_wallet!(org)
end
