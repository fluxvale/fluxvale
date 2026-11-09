defmodule FluxValeWeb.AdminOrgDetailLiveTest do
  @moduledoc false

  # The org detail surface (#501): the wallet summary and the org's
  # instances, rendered exactly as far as each read policy admits. The
  # scope arm is the point: a member admin sees the strip and the
  # table, a non-member admin sees the honest scope note. The route
  # gates ride the shared live_session's arms (the anonymous 302 and
  # the non-admin 403, pinned once per surface).

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.Billing
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    # ResolveCluster pins THE single cluster row — one per sandbox.
    InstanceFixtures.local_cluster!()

    admin =
      User.create!(
        "admin-orgdetail-admin-#{@n}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin), bare_conn: conn}
  end

  # A funded org with the ADMIN as a member, plus the instance
  # fixtures the table renders. The instance create rides the actions
  # with the org's owner as the actor (the funded gate is the create
  # policy's own requirement, so the wallet is funded first).
  defp member_org_with_instances!(admin, status \\ :running) do
    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, _wallet} = Billing.ensure_wallet(org)
    {:ok, _grant} = Billing.grant_credits(org, 10_000, reason: :adjustment)

    Membership.create!(%{organization_id: org.id, user_id: admin.id, role: :member},
      authorize?: false
    )

    built_version = InstanceFixtures.app_version!()
    version = Ash.load!(built_version, :app)

    instances =
      for _i <- 1..2 do
        built = InstanceFixtures.instance!(version, owner)
        InstanceFixtures.walk_to!(built, status)
      end

    {org, instances, version}
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

  describe "the instances, inside the read policy" do
    test "a member admin sees the org's instances with the lifecycle grammar", %{
      conn: conn,
      admin: admin
    } do
      {org, [oldest, newest], version} = member_org_with_instances!(admin, :running)

      {:ok, view, _html} = live(conn, "/admin/orgs/#{org.id}")

      assert has_element?(view, "[data-testid='admin-orgs-detail']")

      # Newest first: the second create's row precedes the first's —
      # read back as data, in DOM order.
      row_ids =
        view
        |> element("#admin-orgs-instances-table")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-testid^='admin-orgs-instance-']")
        |> Enum.map(fn node ->
          node
          |> LazyHTML.attribute("data-testid")
          |> Enum.join("")
          |> String.replace_prefix("admin-orgs-instance-", "")
        end)

      assert row_ids == [newest.id, oldest.id]

      for instance <- [newest, oldest] do
        assert text_of(view, "[data-testid='admin-orgs-instance-#{instance.id}']") =~
                 instance.name

        # App and version ride the loaded blueprint.
        assert text_of(view, "[data-testid='admin-orgs-app-#{instance.id}']") =~
                 version.app.name

        assert text_of(view, "[data-testid='admin-orgs-app-#{instance.id}']") =~
                 "v#{version.version}"

        # The lifecycle badge grammar, never the raw atom.
        assert text_of(view, "[data-testid='admin-orgs-status-#{instance.id}']") == "Running"

        # The allocation the instance actually runs at, and the full
        # text rides the title for the truncate case.
        allocation = "0.5 CPU · 256 MB · 0 GB"

        assert text_of(view, "[data-testid='admin-orgs-allocation-#{instance.id}']") ==
                 allocation

        assert has_element?(
                 view,
                 "[data-testid='admin-orgs-allocation-#{instance.id}'][title='#{allocation}']"
               )

        created = Calendar.strftime(instance.created_at, "%b %d, %Y")
        assert text_of(view, "[data-testid='admin-orgs-created-#{instance.id}']") == created
      end
    end

    test "the lifecycle strip counts the shown page, and sleep reads honestly", %{
      conn: conn,
      admin: admin
    } do
      {org, [sleeping, _other], _version} = member_org_with_instances!(admin, :sleeping)

      {:ok, view, _html} = live(conn, "/admin/orgs/#{org.id}")

      assert text_of(view, "[data-testid='admin-orgs-strip-running']") == "0 running"
      assert text_of(view, "[data-testid='admin-orgs-strip-stopped']") == "0 stopped"
      assert text_of(view, "[data-testid='admin-orgs-strip-sleeping']") == "2 sleeping"

      # The mixed bucket is its own cue: nothing outside the three
      # resting states here.
      assert text_of(view, "[data-testid='admin-orgs-strip-other']") == "0 other"

      # ADR-0036's honest posture: asleep is a resting state the next
      # visitor reverses, at storage-only billing.
      assert has_element?(view, "[data-testid='admin-orgs-sleep-note']")
      assert text_of(view, "[data-testid='admin-orgs-status-#{sleeping.id}']") == "Sleeping"
    end

    test "the strip's other cue names the states the resting rungs omit", %{
      conn: conn,
      admin: admin
    } do
      # One running, one freshly submitted (pending): an "all quiet"
      # reading must not survive a pending-or-errored page.
      {org, owner} = BillingFixtures.grant_free_org!()
      {:ok, _wallet} = Billing.ensure_wallet(org)
      {:ok, _grant} = Billing.grant_credits(org, 10_000, reason: :adjustment)

      Membership.create!(%{organization_id: org.id, user_id: admin.id, role: :member},
        authorize?: false
      )

      version = InstanceFixtures.app_version!()
      built = InstanceFixtures.instance!(version, owner)
      running = InstanceFixtures.walk_to!(built, :running)
      pending = InstanceFixtures.instance!(version, owner)

      {:ok, view, _html} = live(conn, "/admin/orgs/#{org.id}")

      assert text_of(view, "[data-testid='admin-orgs-strip-running']") == "1 running"
      assert text_of(view, "[data-testid='admin-orgs-strip-other']") == "1 other"
      assert text_of(view, "[data-testid='admin-orgs-status-#{running.id}']") == "Running"
      assert text_of(view, "[data-testid='admin-orgs-status-#{pending.id}']") == "Submitted"
    end

    test "a status broadcast moves the strip and the row — live truth, not a snapshot", %{
      conn: conn,
      admin: admin
    } do
      {org, [instance, _other], _version} = member_org_with_instances!(admin, :running)

      {:ok, view, _html} = live(conn, "/admin/orgs/#{org.id}")

      assert text_of(view, "[data-testid='admin-orgs-strip-running']") == "2 running"

      # The product's own write path broadcasts on instances:<id>; the
      # page follows without a reload.
      {:ok, _stopped} = InstanceK8s.update_status(instance, :stopped, nil)

      assert text_of(view, "[data-testid='admin-orgs-strip-running']") == "1 running"
      assert text_of(view, "[data-testid='admin-orgs-strip-stopped']") == "1 stopped"
      assert text_of(view, "[data-testid='admin-orgs-status-#{instance.id}']") == "Stopped"
    end

    test "a destroy broadcast drops the row and the strip follows", %{conn: conn, admin: admin} do
      {org, [instance, other], _version} = member_org_with_instances!(admin, :running)

      {:ok, view, _html} = live(conn, "/admin/orgs/#{org.id}")

      assert text_of(view, "[data-testid='admin-orgs-strip-running']") == "2 running"

      # The never-deployed row hard-deletes synchronously and the
      # :destroy publish rides it.
      Instance.delete(instance.id, actor: admin)

      refute has_element?(view, "[data-testid='admin-orgs-instance-#{instance.id}']")
      assert text_of(view, "[data-testid='admin-orgs-strip-running']") == "1 running"
      assert has_element?(view, "[data-testid='admin-orgs-instance-#{other.id}']")
    end

    test "a destroy that empties the page lands on the empty state", %{conn: conn, admin: admin} do
      # One instance, one broadcast: the strip and the table must not
      # survive as zeroes beside a dangling header.
      {org, owner} = BillingFixtures.grant_free_org!()
      {:ok, _wallet} = Billing.ensure_wallet(org)
      {:ok, _grant} = Billing.grant_credits(org, 10_000, reason: :adjustment)

      Membership.create!(%{organization_id: org.id, user_id: admin.id, role: :member},
        authorize?: false
      )

      version = InstanceFixtures.app_version!()
      instance = InstanceFixtures.instance!(version, owner)

      {:ok, view, _html} = live(conn, "/admin/orgs/#{org.id}")

      assert has_element?(view, "[data-testid='admin-orgs-status-strip']")

      Instance.delete(instance.id, actor: admin)

      assert has_element?(view, "[data-testid='admin-orgs-instances-empty']")
      refute has_element?(view, "[data-testid='admin-orgs-status-strip']")
      refute has_element?(view, "[data-testid='admin-orgs-instances-table']")
    end

    test "a stale notification for a torn-down row must not crash", %{conn: conn, admin: admin} do
      # The exact interleaving the re-read exists for: an update_status
      # notification for a row teardown already deleted.
      {org, [instance, _other], _version} = member_org_with_instances!(admin, :running)

      {:ok, view, _html} = live(conn, "/admin/orgs/#{org.id}")

      Instance.delete(instance.id, actor: admin)

      notification = %Ash.Notifier.Notification{
        resource: Instance,
        action: %{name: :update_status},
        data: instance
      }

      Phoenix.PubSub.broadcast(FluxVale.PubSub, "instances:#{instance.id}", notification)

      refute has_element?(view, "[data-testid='admin-orgs-instance-#{instance.id}']")
    end

    test "a member admin with zero instances gets the honest empty state", %{
      conn: conn,
      admin: admin
    } do
      {org, _owner} = BillingFixtures.grant_free_org!()
      {:ok, _wallet} = Billing.ensure_wallet(org)
      {:ok, _grant} = Billing.grant_credits(org, 10_000, reason: :adjustment)

      Membership.create!(%{organization_id: org.id, user_id: admin.id, role: :member},
        authorize?: false
      )

      {:ok, view, _html} = live(conn, "/admin/orgs/#{org.id}")

      assert has_element?(view, "[data-testid='admin-orgs-instances-empty']")
      refute has_element?(view, "[data-testid='admin-orgs-status-strip']")
      refute has_element?(view, "[data-testid='admin-orgs-instances-hidden']")
    end

    test "real pagination replaces the old cap: 26 instances make two honest pages", %{
      conn: conn,
      admin: admin
    } do
      {org, owner} = BillingFixtures.grant_free_org!()
      {:ok, _wallet} = Billing.ensure_wallet(org)
      {:ok, _grant} = Billing.grant_credits(org, 10_000, reason: :adjustment)

      Membership.create!(%{organization_id: org.id, user_id: admin.id, role: :member},
        authorize?: false
      )

      version = InstanceFixtures.app_version!()

      instances = for _i <- 1..26, do: InstanceFixtures.instance!(version, owner)
      oldest = List.first(instances)
      newest = List.last(instances)

      {:ok, view, _html} = live(conn, "/admin/orgs/#{org.id}")

      # Newest first: a full first page, the oldest instance waiting
      # on page two.
      assert has_element?(
               view,
               "[data-testid='admin-orgs-instances-table-count']",
               "1 to 25 of 26"
             )

      # A column sort swaps the caption honestly: "Newest first" names
      # the default ordering only, the sorted copy names the sort
      # (CodeRabbit, #643). The status/desc pair exercises the
      # remaining label and direction arms (codecov, #643).
      {:ok, sorted_view, _sorted_html} = live(conn, "/admin/orgs/#{org.id}?sort=name&dir=asc")
      sorted_html = render(sorted_view)
      assert sorted_html =~ "Sorted by name"
      refute sorted_html =~ "Newest first"

      {:ok, status_view, _status_html} = live(conn, "/admin/orgs/#{org.id}?sort=status&dir=desc")
      assert render(status_view) =~ "Sorted by status"

      {:ok, created_view, _created_html} =
        live(conn, "/admin/orgs/#{org.id}?sort=created_at&dir=asc")

      assert render(created_view) =~ "Sorted by created date"

      assert has_element?(view, "[data-testid='admin-orgs-instance-#{newest.id}']")
      refute has_element?(view, "[data-testid='admin-orgs-instance-#{oldest.id}']")

      view
      |> element("[data-testid='admin-orgs-instances-table-page-next']")
      |> render_click()

      assert has_element?(view, "[data-testid='admin-orgs-instance-#{oldest.id}']")

      assert has_element?(
               view,
               "[data-testid='admin-orgs-instances-table-page-label']",
               "Page 2 of 2"
             )

      assert_patched(view, "/admin/orgs/#{org.id}?page=2")

      # The table's guard rails: a crafted event is a no-op (the view
      # is unmoved), and a whitelisted sort rides the URL.
      render_click(view, "sort", %{"field" => "not-a-field"})
      render_click(view, "page", %{"nav" => "sideways"})
      render_click(view, "sort", %{})
      render_click(view, "page", %{})
      render_click(view, "size", %{})
      render_click(view, "size", %{"size" => "999"})

      assert has_element?(view, "[data-testid='admin-orgs-instances-table-page-label']")

      {:ok, sorted, _html} = live(conn, "/admin/orgs/#{org.id}?sort=name&dir=asc")

      assert has_element?(sorted, "[data-testid='admin-orgs-instances-table-header-instance']")
    end
  end

  describe "the instances, outside the read policy" do
    test "a non-member admin gets the scope note, not a table and not a crash", %{conn: conn} do
      # A funded org whose instances the admin cannot read: the admin
      # is deliberately NOT a member here.
      {org, owner} = BillingFixtures.grant_free_org!()
      {:ok, _wallet} = Billing.ensure_wallet(org)
      {:ok, _grant} = Billing.grant_credits(org, 10_000, reason: :adjustment)

      version = InstanceFixtures.app_version!()
      instance = InstanceFixtures.instance!(version, owner)

      {:ok, view, _html} = live(conn, "/admin/orgs/#{org.id}")

      assert has_element?(view, "[data-testid='admin-orgs-instances-hidden']")
      assert has_element?(view, "[data-testid='admin-orgs-instances-hidden']", "not a member")
      refute has_element?(view, "[data-testid='admin-orgs-instance-#{instance.id}']")
      refute has_element?(view, "[data-testid='admin-orgs-status-strip']")
    end
  end

  describe "the wallet summary" do
    test "shows the balance, the state badge, the wallet-since stamp, and the detail link", %{
      conn: conn,
      admin: admin
    } do
      {org, _instances, _version} = member_org_with_instances!(admin)

      {:ok, view, _html} = live(conn, "/admin/orgs/#{org.id}")

      assert text_of(view, "[data-testid='admin-orgs-detail-balance']") == "$100.00"

      # Positive is the resting rung: plain, no badge at all.
      assert text_of(view, "[data-testid='admin-orgs-detail-state']") == ""

      {:ok, wallet} = Billing.ensure_wallet(org)
      since = Calendar.strftime(wallet.created_at, "%b %d, %Y")
      assert text_of(view, "[data-testid='admin-orgs-detail-wallet-since']") =~ since

      assert has_element?(
               view,
               "[data-testid='admin-orgs-open-wallet'][href='/admin/billing/wallets/#{wallet.id}']"
             )

      assert has_element?(view, "[data-testid='admin-orgs-open-wallet']", "Open wallet")
    end

    test "an org without a wallet says so instead of pretending", %{conn: conn, admin: admin} do
      # A team org that never touched billing: no wallet to read.
      {org, _owner} = BillingFixtures.grant_free_org!()

      Membership.create!(%{organization_id: org.id, user_id: admin.id, role: :member},
        authorize?: false
      )

      {:ok, view, _html} = live(conn, "/admin/orgs/#{org.id}")

      assert has_element?(view, "[data-testid='admin-orgs-detail-no-wallet']")
      refute has_element?(view, "[data-testid='admin-orgs-open-wallet']")
    end
  end

  describe "missing orgs" do
    test "an unknown id bounces back to the list with the flash", %{conn: conn} do
      missing_id = "00000000-0000-0000-0000-000000000000"

      assert {:error, {:live_redirect, %{to: "/admin/orgs", flash: flash}}} =
               live(conn, "/admin/orgs/#{missing_id}")

      assert flash["error"] == "That org does not exist."
    end

    test "a malformed id takes the same arm, flash and all", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/orgs", flash: flash}}} =
               live(conn, "/admin/orgs/not-a-uuid")

      assert flash["error"] == "That org does not exist."
    end
  end

  describe "the instances controls" do
    test "executes every control, and a page-two broadcast never lands in page one",
         %{conn: conn, admin: admin} do
      {org, owner} = BillingFixtures.grant_free_org!()
      {:ok, _wallet} = Billing.ensure_wallet(org)
      {:ok, _grant} = Billing.grant_credits(org, 10_000, reason: :adjustment)

      Membership.create!(%{organization_id: org.id, user_id: admin.id, role: :member},
        authorize?: false
      )

      version = InstanceFixtures.app_version!()

      instances = for _i <- 1..26, do: InstanceFixtures.instance!(version, owner)
      page_two_instance = List.first(instances)

      {:ok, view, _html} = live(conn, "/admin/orgs/#{org.id}")

      # Sort ascending, then the sorted column flips to descending.
      view
      |> element("[data-testid='admin-orgs-instances-table-sort-name']")
      |> render_click()

      assert attribute(view, "admin-orgs-instances-table-header-instance", "aria-sort") ==
               "ascending"

      view
      |> element("[data-testid='admin-orgs-instances-table-sort-name']")
      |> render_click()

      assert attribute(view, "admin-orgs-instances-table-header-instance", "aria-sort") ==
               "descending"

      # Prev: page two, then back to one.
      view
      |> element("[data-testid='admin-orgs-instances-table-page-next']")
      |> render_click()

      assert text_of(view, "[data-testid='admin-orgs-instances-table-page-label']") =~
               "Page 2 of"

      view
      |> element("[data-testid='admin-orgs-instances-table-page-prev']")
      |> render_click()

      # Every size option executes.
      view
      |> element("[data-testid='admin-orgs-instances-table-size-50']")
      |> render_click()

      assert has_element?(
               view,
               "[data-testid='admin-orgs-instances-table-size-50'][aria-pressed=true]"
             )

      view
      |> element("[data-testid='admin-orgs-instances-table-size-100']")
      |> render_click()

      assert has_element?(
               view,
               "[data-testid='admin-orgs-instances-table-size-100'][aria-pressed=true]"
             )

      view
      |> element("[data-testid='admin-orgs-instances-table-size-25']")
      |> render_click()

      assert has_element?(
               view,
               "[data-testid='admin-orgs-instances-table-size-25'][aria-pressed=true]"
             )

      # The deep-link clamp: a crafted page answers with the last one.
      {:ok, clamped, _html} = live(conn, "/admin/orgs/#{org.id}?page=10000")

      assert text_of(clamped, "[data-testid='admin-orgs-instances-table-page-label']") =~
               "Page 2 of 2"

      # The broadcast-leak probe (the reviewer's shape): back on page
      # one, a status broadcast for a PAGE-TWO instance must not land
      # here — the id left the page, its subscription left with it.
      rows_before =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-testid^='admin-orgs-instance-']")
        |> Enum.count()

      Phoenix.PubSub.broadcast(
        FluxVale.PubSub,
        "instances:#{page_two_instance.id}",
        %Ash.Notifier.Notification{data: struct(Instance, id: page_two_instance.id)}
      )

      # Drain the view's mailbox: a sys round-trip is processed after
      # the pending broadcasts (the sanctioned sync, no sleeps).
      _drained = :sys.get_state(view.pid)

      rows_after =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-testid^='admin-orgs-instance-']")
        |> Enum.count()

      assert rows_before == 25
      assert rows_after == 25
    end
  end

  describe "the gates" do
    test "anonymous bounces to /sign-in", %{bare_conn: conn} do
      conn = get(conn, "/admin/orgs/00000000-0000-0000-0000-000000000000")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "a signed-in non-admin gets a bare 403", %{bare_conn: conn} do
      user = SessionHelpers.user!()
      signed = SessionHelpers.sign_in(conn, user)
      conn = get(signed, "/admin/orgs/00000000-0000-0000-0000-000000000000")

      assert conn.status == 403
    end
  end
end
