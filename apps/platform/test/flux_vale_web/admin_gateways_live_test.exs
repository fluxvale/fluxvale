defmodule FluxValeWeb.AdminGatewaysLiveTest do
  @moduledoc false

  # The gateways surface (#501, #613): the gateway table under the
  # blanket platform-admin authority (#644, ADR-0047). Session reads
  # are cross-org, so the list is EVERY org's gateway — cross-org rows
  # render, and the operator-truth columns (the attention clock here;
  # key age and tailnet claims on the detail page) ride their rows.
  # The provider is Mimic-stubbed (the fixture's contract); the route
  # gates ride the shared live_session's arms.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import Ecto.Query, only: [from: 2]
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

  # `{org, gateway}` on a member org — or, with non_member: true, a
  # stranger org's gateway the blanket authority now RENDERS (#644:
  # cross-org by construction, membership or not).
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

  # User carries no role-write action and Ash.Seed is create-only, so
  # the demotion rides the data layer directly (tests own their
  # preconditions; the per-event gate is what the test pins — the
  # wallet surface's demote shape).
  defp demote!(admin) do
    query = from(u in "users", where: u.id == ^Ecto.UUID.dump!(admin.id))
    {updated, nil} = FluxVale.Repo.update_all(query, set: [platform_role: "user"])
    assert updated == 1
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

    test "the main empty state is the global claim the cross-org read supports", %{conn: conn} do
      # Nothing built: the cross-org read backs a global "no gateways
      # yet" — the old filter-scoped hedging and the membership probe
      # are gone with #613's arm.
      {:ok, view, _html} = live(conn, "/admin/gateways")

      assert has_element?(view, "[data-testid='admin-gateways-empty']", "No gateways yet")
      refute has_element?(view, "[data-testid='admin-gateways-scope-note']")
    end

    test "a stranger org's gateway renders — the blanket widened the read (#644)", %{
      conn: conn,
      admin: admin
    } do
      {stranger_org, foreign} = gateway_for_admin!(admin, non_member: true, state: :active)

      # The org-less shape the old probe served: memberships stripped
      # (the bootstrap stance), and the stranger's row STILL renders —
      # ADR-0047's blanket authority reads cross-org, membership or
      # not — and the scope note is gone with the member-scoped copy.
      Membership
      |> Ash.Query.filter(user_id == ^admin.id)
      |> Ash.read!(authorize?: false)
      |> Enum.each(&Ash.destroy!(&1, authorize?: false))

      signed = SessionHelpers.sign_in(conn, admin)
      {:ok, view, _html} = live(signed, "/admin/gateways")

      assert has_element?(view, "[data-testid='admin-gateways-host-#{foreign.id}']")

      assert text_of(view, "[data-testid='admin-gateways-org-#{foreign.id}']") =~
               stranger_org.name

      # The org-less emptiness the scope note answered cannot happen:
      # no probe renders, whatever the membership table says.
      refute has_element?(view, "[data-testid='admin-gateways-scope-note']")
      refute has_element?(view, "[data-testid='admin-gateways-empty']")
    end

    test "an attention row carries its clock — and the clock keys on the state, not the stamp",
         %{conn: conn, admin: admin} do
      {_org, flagged} = gateway_for_admin!(admin, state: :needs_attention)

      # The funnel is the stamp's only writer (the state alone does not
      # set it), so the clock's row gets it the way production does.
      clocked =
        flagged
        |> Ash.Changeset.for_update(
          :update_state,
          %{needs_attention_since: DateTime.add(DateTime.utc_now(), -2, :day)},
          authorize?: false
        )
        |> Ash.update!()

      # The stale-stamp shape (the pin's finding): Suspend never clears
      # needs_attention_since, so this suspended row carries the anchor
      # — and must NOT show a clock, because the clock keys on the
      # state like the pin does.
      {_stale_org, active} = gateway_for_admin!(admin, state: :active)

      stale =
        active
        |> Ash.Changeset.for_update(
          :update_state,
          %{state: :suspended, needs_attention_since: DateTime.add(DateTime.utc_now(), -1, :day)},
          authorize?: false
        )
        |> Ash.update!()

      {:ok, view, _html} = live(conn, "/admin/gateways")

      since = Calendar.strftime(clocked.needs_attention_since, "%b %d, %Y")

      assert text_of(view, "[data-testid='admin-gateways-attention-since-#{clocked.id}']") ==
               "Since #{since}"

      refute has_element?(view, "[data-testid='admin-gateways-attention-since-#{stale.id}']")
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

      # The table's guard rails: a whitelisted sort rides the URL, a
      # crafted event is a no-op (the list is unmoved).
      render_click(view, "sort", %{"field" => "not-a-field"})
      render_click(view, "page", %{"nav" => "sideways"})
      render_click(view, "sort", %{})
      render_click(view, "page", %{})
      render_click(view, "size", %{})
      render_change(view, "search", %{"search" => %{"query" => %{"deep" => "crafted"}}})

      assert text_of(view, "[data-testid='admin-gateways-table-page-label']") =~ "Page 2 of 2"

      # A garbage size falls back to the default and resets the page
      # with it: the honest fallback, not a silent acceptance.
      render_click(view, "size", %{"size" => "999"})

      assert text_of(view, "[data-testid='admin-gateways-table-page-label']") =~ "Page 1 of"

      {:ok, sorted, _html} = live(conn, "/admin/gateways?sort=hostname&dir=asc")

      assert has_element?(sorted, "[data-testid='admin-gateways-table-header-gateway']")
    end
  end

  describe "the table controls" do
    test "executes every control: sort asc then desc, prev, every size, and the deep-link clamp",
         %{conn: conn, admin: admin} do
      {_org, _gw} = gateway_for_admin!(admin)

      for _n <- 1..25 do
        {_org, _gateway} = gateway_for_admin!(admin)
      end

      {:ok, view, _html} = live(conn, "/admin/gateways")

      # Sort ascending, then the sorted column flips to descending.
      view
      |> element("[data-testid='admin-gateways-table-sort-hostname']")
      |> render_click()

      assert attribute(view, "admin-gateways-table-header-gateway", "aria-sort") == "ascending"

      view
      |> element("[data-testid='admin-gateways-table-sort-hostname']")
      |> render_click()

      assert attribute(view, "admin-gateways-table-header-gateway", "aria-sort") == "descending"

      # Prev: page two, then back to one.
      view
      |> element("[data-testid='admin-gateways-table-page-next']")
      |> render_click()

      view
      |> element("[data-testid='admin-gateways-table-page-prev']")
      |> render_click()

      assert text_of(view, "[data-testid='admin-gateways-table-page-label']") =~ "Page 1 of"

      # Every size option executes.
      view
      |> element("[data-testid='admin-gateways-table-size-50']")
      |> render_click()

      assert has_element?(view, "[data-testid='admin-gateways-table-size-50'][aria-pressed=true]")

      view
      |> element("[data-testid='admin-gateways-table-size-100']")
      |> render_click()

      assert has_element?(
               view,
               "[data-testid='admin-gateways-table-size-100'][aria-pressed=true]"
             )

      view
      |> element("[data-testid='admin-gateways-table-size-25']")
      |> render_click()

      assert has_element?(view, "[data-testid='admin-gateways-table-size-25'][aria-pressed=true]")

      # The deep-link clamp: a crafted page answers with the last one.
      {:ok, clamped, _html} = live(conn, "/admin/gateways?page=10000")

      assert text_of(clamped, "[data-testid='admin-gateways-table-page-label']") =~
               "Page 2 of 2"
    end
  end

  describe "the clear lever" do
    test "the search-empty state's clear lever hands the list back", %{conn: conn, admin: admin} do
      {_org, _gw} = gateway_for_admin!(admin)

      {:ok, view, _html} = live(conn, "/admin/gateways")

      render_change(view, "search", %{"search" => %{"query" => "zzz-no-such-gateway"}})

      assert has_element?(view, "[data-testid='admin-gateways-search-empty']")

      view
      |> element("[data-testid='admin-gateways-clear-search']")
      |> render_click()

      assert has_element?(view, "[data-testid^='admin-gateways-host-']")
      refute has_element?(view, "[data-testid='admin-gateways-search-empty']")
    end
  end

  describe "the per-event demotion seam (the AdminChrome hook)" do
    test "a demoted admin's event is refused with the wallet surface's copy", %{
      conn: conn,
      admin: admin
    } do
      {_org, gateway} = gateway_for_admin!(admin, state: :active)

      {:ok, view, _html} = live(conn, "/admin/gateways")

      demote!(admin)

      # The READ window stays (the mounted DOM is stale until the next
      # interaction — ADR-0047 D4), and the FIRST interaction is where
      # the shared hook answers: every event re-resolves the actor.
      html = render_change(view, "search", %{"search" => %{"query" => "zzz-no-such"}})

      assert html =~ "Your admin access ended. Sign out and sign back in."

      # The halt landed BEFORE the surface's own handler: the list
      # keeps its mounted rows, and the search's no-match state never
      # rendered.
      assert has_element?(view, "[data-testid='admin-gateways-host-#{gateway.id}']")
      refute has_element?(view, "[data-testid='admin-gateways-search-empty']")
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
