defmodule FluxValeWeb.AdminGatewaysLiveTest do
  @moduledoc false

  # The gateways surface (#501): the gateway table and its
  # member-scoped honesty. The gateway read policy is a members-only
  # filter with no platform-admin arm, so the list renders EXACTLY the
  # member-org gateways — the policy-exact rendering is the point, and
  # these tests pin it. The provider is Mimic-stubbed (the fixture's
  # contract); the route gates ride the shared live_session's arms.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers
  alias FluxVale.TestSupport.StorageRequestFixtures

  require Ash.Query

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
    stub(Tailscale, :teardown_gateway, fn _gateway -> :ok end)

    admin =
      User.create!(
        "admin-gateways-admin-#{@n}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin), bare_conn: conn}
  end

  # `{org, gateway}` on an org the admin belongs to — or, with
  # non_member: true, a stranger org's gateway the list must NOT
  # render. The membership row is the read policy's only door.
  defp gateway_for_admin!(admin, opts \\ []) do
    {org, _owner} = BillingFixtures.grant_free_org!()

    unless opts[:non_member] do
      Membership.create!(%{organization_id: org.id, user_id: admin.id, role: :member},
        authorize?: false
      )
    end

    gateway = AccessFixtures.gateway!(org, Keyword.take(opts, [:state, :tailnet_domain]))

    {org, gateway}
  end

  defp text_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  describe "the gateway table" do
    test "carries the pending storage-request badge", %{conn: conn} do
      user = AccountsFixtures.user!()
      InstanceFixtures.local_cluster!()
      version = InstanceFixtures.app_version!(default_storage_gb: 10, monthly_cents: 100)

      instance =
        Instance.create!(
          %{
            name: "gateways-badge-#{System.unique_integer([:positive])}",
            app_version_id: version.id,
            env_vars: %{}
          },
          actor: user
        )

      StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      {:ok, view, _html} = live(conn, "/admin/gateways")

      assert text_of(view, "[data-testid='admin-pending-storage-requests']") == "1"
    end

    test "lists a member org's gateway with the policy-admitted columns", %{
      conn: conn,
      admin: admin
    } do
      {org, gateway} = gateway_for_admin!(admin, state: :active)

      {:ok, view, _html} = live(conn, "/admin/gateways")

      assert has_element?(view, "[data-testid='admin-gateways']")

      assert text_of(view, "[data-testid='admin-gateways-org-#{gateway.id}']") =~ org.name
      assert text_of(view, "[data-testid='admin-gateways-org-#{gateway.id}']") =~ org.slug

      # The identifier grammar the product uses: opaque hostname, then
      # the tailnet domain it serves under.
      host = text_of(view, "[data-testid='admin-gateways-host-#{gateway.id}']")
      assert host =~ gateway.hostname
      assert host =~ gateway.tailnet_domain

      # The product's own state vocabulary, never the raw atom.
      assert text_of(view, "[data-testid='admin-gateways-state-#{gateway.id}']") == "Connected"

      # The shape cue rides the badge: no two states share tone AND
      # shape, and the still frame must tell the states apart (the
      # review's blocker).
      assert has_element?(
               view,
               "[data-testid='admin-gateways-state-#{gateway.id}'] .hero-check-circle"
             )

      assert text_of(view, "[data-testid='admin-gateways-rate-#{gateway.id}']") =~ "$2.00"
      assert text_of(view, "[data-testid='admin-gateways-rate-#{gateway.id}']") =~ "per month"

      created = Calendar.strftime(gateway.created_at, "%b %d, %Y")
      assert text_of(view, "[data-testid='admin-gateways-created-#{gateway.id}']") == created

      assert has_element?(
               view,
               "[data-testid='admin-gateways-open-#{gateway.id}'][href='/admin/gateways/#{gateway.id}']"
             )
    end

    test "every gateway state carries its own shape cue", %{conn: conn, admin: admin} do
      cue_by_state = [
        {:provisioning, "Connecting", ".hero-bolt"},
        {:active, "Connected", ".hero-check-circle"},
        {:needs_attention, "Needs attention", ".hero-exclamation-triangle"},
        {:suspended, "Suspended", ".hero-pause"},
        {:destroying, "Removing", ".hero-trash"}
      ]

      built =
        for {state, label, icon} <- cue_by_state do
          {_org, gateway} = gateway_for_admin!(admin, state: state)
          {gateway.id, label, icon}
        end

      {:ok, view, _html} = live(conn, "/admin/gateways")

      # One label, one shape per section: the shared labels resolve to
      # the same icons their domain namesakes carry (triangle, pause),
      # and Connecting/Removing move on their own icons.
      for {id, label, icon} <- built do
        assert text_of(view, "[data-testid='admin-gateways-state-#{id}']") == label
        assert has_element?(view, "[data-testid='admin-gateways-state-#{id}'] " <> icon)
      end
    end

    test "the main empty state is filter-scoped, never a global claim", %{
      conn: conn,
      admin: admin
    } do
      {org, _owner} = BillingFixtures.grant_free_org!()

      Membership.create!(%{organization_id: org.id, user_id: admin.id, role: :member},
        authorize?: false
      )

      {:ok, view, _html} = live(conn, "/admin/gateways")

      # The title names the orgs this admin belongs to — the
      # member-scoped read cannot support "no gateways anywhere".
      assert has_element?(
               view,
               "[data-testid='admin-gateways-empty']",
               "No gateways in the orgs you belong to"
             )

      refute has_element?(view, "[data-testid='admin-gateways-scope-note']")
    end

    test "an org-less admin sees a stranger's gateway — the blanket widened the read (#644)", %{
      conn: conn,
      admin: admin
    } do
      {_stranger_org, hidden} = gateway_for_admin!(admin, non_member: true, state: :active)

      # The setup admin's JIT personal-org membership is the only row
      # between them and the org-less shape: the system-op posture
      # removes it (the bootstrap stance — membership rows are
      # system-created in seeds too).
      Membership
      |> Ash.Query.filter(user_id == ^admin.id)
      |> Ash.read!(authorize?: false)
      |> Enum.each(&Ash.destroy!(&1, authorize?: false))

      signed = SessionHelpers.sign_in(conn, admin)
      {:ok, view, _html} = live(signed, "/admin/gateways")

      # ADR-0047: platform-admin reads are cross-org by construction,
      # membership or not — the row is there and no empty state
      # renders. (The scope note itself is membership-probed copy the
      # A1-S2 console pass rewords.)
      assert has_element?(view, "[data-testid='admin-gateways-host-#{hidden.id}']")
      refute has_element?(view, "[data-testid='admin-gateways-empty']")
      refute has_element?(view, "[data-testid='admin-gateways-scope-note']")
    end

    test "search narrows by hostname or org name, and never reaches past the list", %{
      conn: conn,
      admin: admin
    } do
      {alpha_org, alpha} = gateway_for_admin!(admin, tailnet_domain: "alpha.ts.net")
      {beta_org, beta} = gateway_for_admin!(admin, tailnet_domain: "beta.ts.net")

      # The fixtures share a display name ("billing-fixture"), so the
      # name arm needs a distinct one: the rename action is owner-gated,
      # so the precondition rides the seeds posture (the orgs surface's
      # stance).
      renamed =
        Organization.update!(alpha_org, %{name: "alpha gateway co #{@n}"}, authorize?: false)

      {:ok, view, _html} = live(conn, "/admin/gateways")

      render_change(view, "search", %{"search" => %{"query" => alpha.hostname}})

      assert has_element?(view, "[data-testid='admin-gateways-host-#{alpha.id}']")
      refute has_element?(view, "[data-testid='admin-gateways-host-#{beta.id}']")

      # The org name is the other way in (whose gateway it is).
      render_change(view, "search", %{"search" => %{"query" => renamed.name}})
      assert has_element?(view, "[data-testid='admin-gateways-host-#{alpha.id}']")
      refute has_element?(view, "[data-testid='admin-gateways-host-#{beta.id}']")

      # The slug is the org's address: the third way in (the name
      # clause's sibling).
      render_change(view, "search", %{"search" => %{"query" => beta_org.slug}})
      assert has_element?(view, "[data-testid='admin-gateways-host-#{beta.id}']")
      refute has_element?(view, "[data-testid='admin-gateways-host-#{alpha.id}']")

      # Clearing hands the whole list back.
      render_change(view, "search", %{"search" => %{"query" => ""}})
      assert has_element?(view, "[data-testid='admin-gateways-host-#{alpha.id}']")
      assert has_element?(view, "[data-testid='admin-gateways-host-#{beta.id}']")

      # A match-shaped string that is nobody's gateway: the honest
      # no-match state.
      render_change(view, "search", %{"search" => %{"query" => "zzz-no-such-gateway"}})
      assert has_element?(view, "[data-testid='admin-gateways-search-empty']")

      # A bare wildcard is a LITERAL under the escaping (the #603
      # class): it matches nothing, it does not match everything.
      render_change(view, "search", %{"search" => %{"query" => "%"}})
      assert has_element?(view, "[data-testid='admin-gateways-search-empty']")
      refute has_element?(view, "[data-testid='admin-gateways-host-#{alpha.id}']")
      refute has_element?(view, "[data-testid='admin-gateways-host-#{beta.id}']")
    end

    test "a gateway whose STATE is flagged pins to the top, built first like the seed's shape", %{
      conn: conn,
      admin: admin
    } do
      # The flagged row is created FIRST — created_at desc alone would
      # land it last, so the assertion fails if the state-keyed sort is
      # deleted. The stamp rides the state funnel (the seed's shape).
      {flagged_org, flagged} = gateway_for_admin!(admin, state: :needs_attention)

      # The stale-stamp shape the finding names: Suspend does not clear
      # needs_attention_since, so this suspended row carries the anchor
      # — and must NOT pin, because the pin keys on the state.
      {stale_org, stale_gateway} = gateway_for_admin!(admin, state: :active)

      stale_row =
        stale_gateway
        |> Ash.Changeset.for_update(
          :update_state,
          %{state: :suspended, needs_attention_since: DateTime.add(DateTime.utc_now(), -1, :day)},
          authorize?: false
        )
        |> Ash.update!()

      {_healthy_org, healthy} = gateway_for_admin!(admin, state: :active)

      {:ok, view, _html} = live(conn, "/admin/gateways")

      assert text_of(view, "[data-testid='admin-gateways-state-#{flagged.id}']") ==
               "Needs attention"

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#admin-gateways-table > div")
        |> Enum.map(fn row ->
          row
          |> LazyHTML.query("[data-testid^='admin-gateways-host-']")
          |> Enum.at(0)
          |> LazyHTML.attribute("data-testid")
          |> Enum.join("")
          |> String.replace_prefix("admin-gateways-host-", "")
        end)

      # The flagged row pins (it is the OLDEST row here — the pin is
      # the state, not recency); the suspended stale-stamp row stays in
      # provisioning order; the newest active leads the rest.
      assert ids == [flagged.id, healthy.id, stale_row.id]

      assert flagged_org
      assert stale_org
    end

    test "real pagination replaces the old cap: a full first page and a second page", %{
      conn: conn,
      admin: admin
    } do
      {_oldest_org, oldest} = gateway_for_admin!(admin)

      newest =
        for _n <- 1..25 do
          {_org, gateway} = gateway_for_admin!(admin)
          gateway
        end
        |> List.last()

      {:ok, view, _html} = live(conn, "/admin/gateways")

      # A full first page, the oldest row waiting on page two.
      assert has_element?(view, "[data-testid='admin-gateways-table-count']", "1 to 25 of 26")

      assert text_of(view, "[data-testid='admin-gateways-table-page-label']") =~ "Page 1 of 2"
      assert has_element?(view, "[data-testid='admin-gateways-host-#{newest.id}']")
      refute has_element?(view, "[data-testid='admin-gateways-host-#{oldest.id}']")

      view
      |> element("[data-testid='admin-gateways-table-page-next']")
      |> render_click()

      # Provisioning order, newest first: page two carries the oldest.
      assert has_element?(view, "[data-testid='admin-gateways-host-#{oldest.id}']")
      assert text_of(view, "[data-testid='admin-gateways-table-page-label']") =~ "Page 2 of 2"
      assert_patched(view, "/admin/gateways?page=2")
    end
  end

  describe "the gates" do
    test "anonymous bounces to /sign-in", %{bare_conn: conn} do
      conn = get(conn, "/admin/gateways")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "a signed-in non-admin gets a bare 403", %{bare_conn: conn} do
      user = SessionHelpers.user!()
      signed = SessionHelpers.sign_in(conn, user)
      conn = get(signed, "/admin/gateways")

      assert conn.status == 403
    end
  end
end
