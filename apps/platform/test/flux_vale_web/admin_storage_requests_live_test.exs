defmodule FluxValeWeb.AdminStorageRequestsLiveTest do
  @moduledoc """
  The operator storage-request queue (#250, ADR-0046 D5/D6): the live
  list, the URL-driven status/search filters, the keyset pagination
  (cursors, sizes, the created-at sort), the approval's online grow,
  the rejection's member-visible feedback, the retry after a failed apply,
  the capability/wallet/stale refusals, the live badge, and the
  demotion-window write gate.

  The K8s surface is Mimic-stubbed exactly like the storage-request
  operations suite (the LiveView process runs the stubs), so a green
  approve test proves the cluster calls it claims.
  """

  use FluxValeWeb.ConnCase, async: false
  use Mimic

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.StorageClass
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.StorageRequest
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers
  alias FluxVale.TestSupport.StorageRequestFixtures
  alias FluxValeWeb.AdminChrome
  alias FluxValeWeb.Components.AdminDataTable

  @n :erlang.unique_integer([:positive])

  setup :verify_on_exit!

  setup %{conn: conn} do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

    admin =
      User.create!(
        "admin-storage-queue-#{@n}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin)}
  end

  # -- preconditions --------------------------------------------------------

  defp user!, do: AccountsFixtures.user!()

  # One local cluster per test (the ResolveCluster contract): every
  # instance the test builds pins to it.
  defp cluster!, do: InstanceFixtures.local_cluster!()

  defp version!, do: InstanceFixtures.app_version!(default_storage_gb: 10, monthly_cents: 100)

  defp instance!(version, user, opts \\ []) do
    name = Keyword.get(opts, :name, "queue-#{System.unique_integer([:positive])}")

    created =
      Instance.create!(%{name: name, app_version_id: version.id, env_vars: %{}}, actor: user)

    if Keyword.get(opts, :running, false) do
      running = InstanceFixtures.walk_to!(created, :running)
      InstanceFixtures.pin!(running, namespace: "fluxvale-app-#{created.id}")
    else
      created
    end
  end

  # The org's wallet must be funded for an approval (the resize's #124
  # gate). The personal org is the instance's org (SetOrganizationFromActor).
  defp fund_org!(user) do
    org = AccountsFixtures.personal_org!(user)
    {funded, _wallet} = BillingFixtures.funded_wallet!(org: org)
    funded
  end

  # The N→M grow's cluster: quota at the new storage, the live claim's
  # 10 Gi, the PVC patch at the requested total.
  defp stub_growth!(requested_gb, live_gb) do
    stub(ResourceQuota, :create, fn _kc, _ns, "app-quota", spec ->
      assert spec.storage == requested_gb
      {:ok, %{}}
    end)

    stub(PersistentVolumeClaim, :get, fn _kc, _ns, "app-data" ->
      {:ok, %{"spec" => %{"resources" => %{"requests" => %{"storage" => "#{live_gb}Gi"}}}}}
    end)

    stub(PersistentVolumeClaim, :upsert, fn _kc, _ns, "app-data", spec ->
      assert spec.size == "#{requested_gb}Gi"
      {:ok, %{}}
    end)
  end

  defp text_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  defp open!(view, id), do: render_click(view, "open-request", %{"id" => id})

  # -- list and filters -----------------------------------------------------

  describe "the queue list" do
    test "lists the row context and the Requested count on the sidebar badge", %{conn: conn} do
      user = user!()
      cluster!()
      instance = instance!(version!(), user, name: "Archive box")
      org = AccountsFixtures.personal_org!(user)

      request =
        StorageRequestFixtures.request!(instance, user, %{
          requested_gb: 150,
          reason: "Need room for archives"
        })

      {:ok, view, _html} = live(conn, "/admin/storage-requests")

      assert has_element?(view, "[data-testid='admin-storage-requests']")

      assert has_element?(
               view,
               "[data-testid='admin-storage-requests-filter-requested'][aria-pressed='true']"
             )

      assert text_of(view, "[data-testid='admin-storage-requests-count-requested']") == "1"
      assert text_of(view, "[data-testid='admin-pending-storage-requests']") == "1"

      assert text_of(view, "[data-testid='admin-storage-requests-instance-#{request.id}']") ==
               "Archive box"

      assert text_of(view, "[data-testid='admin-storage-requests-org-#{request.id}']") == org.name

      assert text_of(view, "[data-testid='admin-storage-requests-reason-#{request.id}']") ==
               "Need room for archives"

      assert text_of(view, "[data-testid='admin-storage-requests-storage-#{request.id}']") =~
               "10 → 150 GB"

      assert text_of(view, "[data-testid='admin-storage-requests-requester-#{request.id}']") ==
               user.username

      assert text_of(view, "[data-testid='admin-storage-requests-rate-#{request.id}']") =~ "/mo"

      assert text_of(view, "[data-testid='admin-storage-requests-status-#{request.id}']") ==
               "Requested"
    end

    test "the status chips and the search narrow one list", %{conn: conn} do
      user = user!()
      cluster!()
      version = version!()
      archives = instance!(version, user)
      videos = instance!(version, user)

      StorageRequestFixtures.request!(archives, user, %{
        requested_gb: 150,
        reason: "Archive vault"
      })

      StorageRequestFixtures.request!(videos, user, %{
        requested_gb: 200,
        reason: "Video exports"
      })

      {:ok, view, _html} = live(conn, "/admin/storage-requests")

      # Default: Requested, both rows.
      assert render(view) =~ "Archive vault"
      assert render(view) =~ "Video exports"

      # The Approved chip narrows to nothing yet, and the URL states it.
      render_click(view, "filter-status", %{"status" => "approved"})
      assert_patched(view, "/admin/storage-requests?status=approved")
      assert has_element?(view, "[data-testid='admin-storage-requests-empty']")
      refute render(view) =~ "Archive vault"

      # A reload of the patched URL lands on the same view.
      {:ok, approved_view, _html} = live(conn, "/admin/storage-requests?status=approved")
      assert has_element?(approved_view, "[data-testid='admin-storage-requests-empty']")
      refute render(approved_view) =~ "Archive vault"

      # The All chip (and its "all" spelling) restores the unfiltered
      # list at ?status=all.
      render_click(view, "filter-status", %{"status" => ""})
      assert_patched(view, "/admin/storage-requests?status=all")
      assert render(view) =~ "Archive vault"
      assert render(view) =~ "Video exports"

      {:ok, all_view, _html} = live(conn, "/admin/storage-requests?status=all")
      assert render(all_view) =~ "Archive vault"
      assert render(all_view) =~ "Video exports"

      render_click(view, "filter-status", %{"status" => "all"})
      assert_patched(view, "/admin/storage-requests?status=all")

      # The search narrows by the reason and rides ?q= (the table's
      # canonical params ride ahead of the status extra).
      view
      |> element("#admin-storage-requests-search")
      |> render_change(%{"search" => %{"query" => "ARCHIV"}})

      assert_patched(view, "/admin/storage-requests?q=ARCHIV&status=all")
      assert render(view) =~ "Archive vault"
      refute render(view) =~ "Video exports"

      {:ok, reloaded, _html} = live(conn, "/admin/storage-requests?q=ARCHIV&status=all")
      assert render(reloaded) =~ "Archive vault"
      refute render(reloaded) =~ "Video exports"

      # Clearing the search removes ?q= from the URL.
      view
      |> element("#admin-storage-requests-search")
      |> render_change(%{"search" => %{"query" => ""}})

      assert_patched(view, "/admin/storage-requests?status=all")
      assert render(view) =~ "Archive vault"
      assert render(view) =~ "Video exports"

      # A crafted status frame is a no-op: the view and its URL stand.
      render_click(view, "filter-status", %{"status" => "nope"})
      assert render(view) =~ "Archive vault"
      assert render(view) =~ "Video exports"
    end

    test "an empty queue names the honest state", %{conn: conn} do
      cluster!()

      {:ok, view, _html} = live(conn, "/admin/storage-requests")

      assert has_element?(view, "[data-testid='admin-storage-requests-empty']")
      assert render(view) =~ "No requests waiting."
      assert text_of(view, "[data-testid='admin-storage-requests-count-requested']") == "0"
      refute has_element?(view, "[data-testid='admin-pending-storage-requests']")
    end

    # Bulk closed history the create action deliberately refuses (one
    # open request per instance): Ash.Seed for the volume, each row a
    # distinct clock (offset 1 is the oldest), and a nil advisory quote
    # (the rate's dash).
    defp seed_rejected!(instance, user, offsets) do
      created = DateTime.add(DateTime.utc_now(), -10_000, :second)

      for offset <- offsets do
        Ash.Seed.seed!(StorageRequest, %{
          instance_id: instance.id,
          organization_id: instance.organization_id,
          requested_gb: 150,
          current_storage_gb: 10,
          reason: "Seeded history #{offset}",
          status: :rejected,
          requested_by_user_id: user.id,
          quoted_monthly_cents: nil,
          created_at: DateTime.add(created, offset, :second)
        })
      end
    end

    # The keyset cursor the surface's own read mints at a window's
    # edge, so a patched URL is asserted byte-for-byte against the
    # URL the view builds with the same public pieces.
    defp queue_cursor!(admin, args, page) do
      {:ok, edge} = StorageRequest.queue(args, actor: admin, page: page)
      List.first(edge.results).__metadata__.keyset
    end

    defp queue_last_cursor!(admin, args, page) do
      {:ok, edge} = StorageRequest.queue(args, actor: admin, page: page)
      List.last(edge.results).__metadata__.keyset
    end

    test "the queue pages keyset-style with real cursors and page sizes", %{
      conn: conn,
      admin: admin
    } do
      user = user!()
      cluster!()
      instance = instance!(version!(), user)

      rows = seed_rejected!(instance, user, 1..26)
      oldest_id = List.first(rows).id

      {:ok, view, _html} = live(conn, "/admin/storage-requests?status=all")

      # Page one: the 25 newest (offsets 26..2), the honest count, and
      # one-way navigation.
      rows_on_page = requests(view)
      assert length(rows_on_page) == 25
      refute oldest_id in rows_on_page

      assert text_of(view, "[data-testid='admin-storage-requests-count']") ==
               "Showing 25 entries."

      assert has_element?(view, "[data-testid='admin-storage-requests-page-next']")
      assert has_element?(view, "[data-testid='admin-storage-requests-page-prev'][disabled]")

      # The old cap copy is retired.
      refute has_element?(view, "[data-testid='admin-storage-requests-more']")
      refute render(view) =~ "Showing the latest 100 requests."

      # Next rides a real cursor in the URL.
      view
      |> element("[data-testid='admin-storage-requests-page-next']")
      |> render_click()

      next_state = %{
        query: "",
        sort: nil,
        page: 1,
        size: 25,
        after: queue_last_cursor!(admin, %{status: nil}, limit: 25),
        before: nil
      }

      next_url =
        AdminDataTable.url_for("/admin/storage-requests", next_state, [{"status", "all"}])

      assert_patched(view, next_url)

      # Page two holds only what page one did not: the oldest row.
      assert requests(view) == [oldest_id]

      assert text_of(view, "[data-testid='admin-storage-requests-count']") ==
               "Showing 1 entries."

      # Prev mirrors it back to the first window.
      view
      |> element("[data-testid='admin-storage-requests-page-prev']")
      |> render_click()

      prev_state = %{
        query: "",
        sort: nil,
        page: 1,
        size: 25,
        after: nil,
        before: queue_cursor!(admin, %{status: nil}, limit: 25, after: next_state.after)
      }

      prev_url =
        AdminDataTable.url_for("/admin/storage-requests", prev_state, [{"status", "all"}])

      assert_patched(view, prev_url)

      assert length(requests(view)) == 25
      assert has_element?(view, "[data-testid='admin-storage-requests-page-prev'][disabled]")

      # A bigger window rides the size event: the URL states it
      # (canonical size param ahead of the status extra) and the
      # cursors dropped.
      view
      |> element("[data-testid='admin-storage-requests-size-50']")
      |> render_click()

      assert_patched(view, "/admin/storage-requests?size=50&status=all")

      assert length(requests(view)) == 26

      assert text_of(view, "[data-testid='admin-storage-requests-count']") ==
               "Showing 26 entries."

      assert has_element?(view, "[data-testid='admin-storage-requests-page-next'][disabled]")

      # A crafted size falls back to the default 25.
      {:ok, crafted_size_view, _html} = live(conn, "/admin/storage-requests?status=all&size=999")

      assert length(requests(crafted_size_view)) == 25

      assert text_of(crafted_size_view, "[data-testid='admin-storage-requests-count']") ==
               "Showing 25 entries."
    end

    test "crafted params fall back honestly", %{conn: conn} do
      user = user!()
      cluster!()
      instance = instance!(version!(), user)
      request = StorageRequestFixtures.request!(instance, user)

      # An unknown status reads the default Requested view.
      {:ok, nope_view, _html} = live(conn, "/admin/storage-requests?status=nope")

      assert has_element?(
               nope_view,
               "[data-testid='admin-storage-requests-filter-requested'][aria-pressed='true']"
             )

      assert has_element?(
               nope_view,
               "[data-testid='admin-storage-requests-instance-#{request.id}']"
             )

      # A real event from that fallback view patches without the status
      # param: the default view's spelling is the bare path.
      nope_view
      |> element("#admin-storage-requests-search")
      |> render_change(%{"search" => %{"query" => "ARCHIV"}})

      assert_patched(nope_view, "/admin/storage-requests?q=ARCHIV")

      # ?page= is harmless: the keyset ignores it and answers page one.
      {:ok, paged_view, _html} = live(conn, "/admin/storage-requests?page=abc")

      assert has_element?(
               paged_view,
               "[data-testid='admin-storage-requests-instance-#{request.id}']"
             )
    end

    test "the created-at sort toggles direction and rides the URL", %{conn: conn} do
      user = user!()
      cluster!()
      instance = instance!(version!(), user)

      rows = seed_rejected!(instance, user, 1..3)
      oldest_id = List.first(rows).id
      newest_id = List.last(rows).id

      {:ok, view, _html} = live(conn, "/admin/storage-requests?status=all")

      # The default order is newest first.
      rendered_default = requests(view)
      assert List.first(rendered_default) == newest_id

      view
      |> element("[data-testid='admin-storage-requests-sort-created_at']")
      |> render_click()

      assert_patched(view, "/admin/storage-requests?sort=created_at&dir=asc&status=all")
      rendered_asc = requests(view)
      assert List.first(rendered_asc) == oldest_id

      view
      |> element("[data-testid='admin-storage-requests-sort-created_at']")
      |> render_click()

      assert_patched(view, "/admin/storage-requests?sort=created_at&dir=desc&status=all")
      rendered_desc = requests(view)
      assert List.first(rendered_desc) == newest_id
    end

    test "changing the sort drops the cursors and restarts at page one", %{conn: conn} do
      user = user!()
      cluster!()
      instance = instance!(version!(), user)

      seed_rejected!(instance, user, 1..30)

      {:ok, view, _html} = live(conn, "/admin/storage-requests?status=all")
      assert length(requests(view)) == 25

      view
      |> element("[data-testid='admin-storage-requests-page-next']")
      |> render_click()

      assert length(requests(view)) == 5

      view
      |> element("[data-testid='admin-storage-requests-sort-created_at']")
      |> render_click()

      # The patched URL carries the new sort and NO cursor: the window
      # restarted at page one under the new order.
      assert_patched(view, "/admin/storage-requests?sort=created_at&dir=asc&status=all")
      assert length(requests(view)) == 25
    end

    test "crafted filter/search frames are no-ops", %{conn: conn} do
      user = user!()
      cluster!()
      instance = instance!(version!(), user)
      StorageRequestFixtures.request!(instance, user)

      {:ok, view, _html} = live(conn, "/admin/storage-requests")

      render_click(view, "filter-status", %{"status" => 123})
      render_click(view, "search", %{"search" => %{"query" => 123}})
      render_click(view, "sort", %{"field" => "not-a-field"})
      render_click(view, "sort", %{})
      render_click(view, "page", %{"nav" => "sideways"})
      render_click(view, "size", %{"size" => 123})
      render_click(view, "reject", %{"nope" => "x"})

      assert has_element?(view, "[data-testid='admin-storage-requests']")
    end

    test "a nil cursor is a no-op, not a crash", %{conn: conn} do
      user = user!()
      cluster!()
      instance = instance!(version!(), user)
      StorageRequestFixtures.request!(instance, user)

      {:ok, view, _html} = live(conn, "/admin/storage-requests")

      # No next cursor exists on a one-page queue: the frame is honest
      # about doing nothing.
      render_click(view, "page", %{"nav" => "next"})

      assert has_element?(view, "[data-testid='admin-storage-requests']")
    end
  end

  # -- the detail -----------------------------------------------------------

  describe "the request detail" do
    test "shows the live instance context, wallet, capability, and charged rate", %{conn: conn} do
      user = user!()
      cluster!()
      fund_org!(user)
      instance = instance!(version!(), user, running: true)
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      {:ok, view, _html} = live(conn, "/admin/storage-requests")
      open!(view, request.id)

      assert text_of(view, "[data-testid='admin-storage-request-instance']") == instance.name
      assert text_of(view, "[data-testid='admin-storage-request-instance-status']") == "Running"
      assert text_of(view, "[data-testid='admin-storage-request-allocation']") =~ "10 GB"

      assert text_of(view, "[data-testid='admin-storage-request-capability']") ==
               "Expansion available"

      assert text_of(view, "[data-testid='admin-storage-request-wallet']") == "Wallet funded"
      assert text_of(view, "[data-testid='admin-storage-request-preview']") =~ "/mo"
      assert render(view) =~ "The instance keeps running; a restart may be needed"

      # The reject form states the member-visible contract.
      assert render(view) =~ "This goes to the customer verbatim."
    end

    test "an unpriced version reads the advisory rate copy", %{conn: conn} do
      user = user!()
      cluster!()
      fund_org!(user)

      # An unpriced preview (the advisory arm): the quote and the detail
      # both answer the advisory copy, never a guessed number. Every
      # shipped size carries a price, so the seam is stubbed.
      Mimic.copy(FluxVale.Infrastructure.Operations.ResizePreview)

      stub(FluxVale.Infrastructure.Operations.ResizePreview, :call, fn _instance, _allocation ->
        {:ok, nil}
      end)

      instance = instance!(version!(), user, running: true)
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      {:ok, view, _html} = live(conn, "/admin/storage-requests")
      open!(view, request.id)

      assert text_of(view, "[data-testid='admin-storage-request-preview']") ==
               "Price confirmed at approval"

      assert text_of(view, "[data-testid='admin-storage-requests-rate-#{request.id}']") == "—"
    end

    test "a non-growth status disables approve with the honest reason", %{conn: conn} do
      user = user!()
      cluster!()
      fund_org!(user)

      # A pending instance has no volume yet: the decision must refuse.
      instance = instance!(version!(), user)
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      {:ok, view, _html} = live(conn, "/admin/storage-requests")
      open!(view, request.id)

      assert has_element?(view, "[data-testid='admin-storage-request-approve'][disabled]")

      assert text_of(view, "[data-testid='admin-storage-request-approve-blocker']") =~
               "The instance is Submitted"
    end

    test "a capability false disables approve", %{conn: conn} do
      user = user!()
      cluster!()
      fund_org!(user)
      instance = instance!(version!(), user, running: true)
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      stub(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, false} end)

      {:ok, view, _html} = live(conn, "/admin/storage-requests")
      open!(view, request.id)

      assert has_element?(view, "[data-testid='admin-storage-request-approve'][disabled]")

      assert text_of(view, "[data-testid='admin-storage-request-approve-blocker']") =~
               "Storage can't be expanded on this cluster yet"
    end

    test "a capability probe error disables approve with the try-again arm", %{conn: conn} do
      user = user!()
      cluster!()
      fund_org!(user)
      instance = instance!(version!(), user, running: true)
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      stub(StorageClass, :default_allows_expansion?, fn _kc ->
        {:error, Error.connection_error("api server on fire")}
      end)

      {:ok, view, _html} = live(conn, "/admin/storage-requests")
      open!(view, request.id)

      assert has_element?(view, "[data-testid='admin-storage-request-approve'][disabled]")

      assert text_of(view, "[data-testid='admin-storage-request-approve-blocker']") =~
               "The storage expansion check failed"
    end

    test "an unfunded wallet disables approve", %{conn: conn} do
      user = user!()
      cluster!()
      instance = instance!(version!(), user, running: true)

      # The instance exists first (create is wallet-gated); drain after.
      org = AccountsFixtures.personal_org!(user)
      BillingFixtures.drain_wallet!(org)

      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      {:ok, view, _html} = live(conn, "/admin/storage-requests")
      open!(view, request.id)

      assert has_element?(view, "[data-testid='admin-storage-request-approve'][disabled]")

      assert text_of(view, "[data-testid='admin-storage-request-approve-blocker']") =~
               "The organization's wallet isn't funded"
    end

    test "a stale target disables approve and a direct click refuses honestly", %{conn: conn} do
      user = user!()
      cluster!()
      fund_org!(user)
      instance = instance!(version!(), user, running: true)
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      # The member resized to the target between request and approve: the
      # request is stale, and the operator's honest move is to reject.
      InstanceFixtures.pin!(instance, storage_gb: 150)

      {:ok, view, _html} = live(conn, "/admin/storage-requests")
      open!(view, request.id)

      assert has_element?(view, "[data-testid='admin-storage-request-approve'][disabled]")

      assert text_of(view, "[data-testid='admin-storage-request-approve-blocker']") =~
               "The instance already has 150 GB"

      # A crafted frame still reaches the action; its refusal is the flash.
      render_click(view, "approve", %{"id" => request.id})
      assert render(view) =~ "already has 150 GB"

      assert %{status: :requested} = Ash.get!(StorageRequest, request.id, authorize?: false)
    end

    test "an unknown request id refreshes with the gone flash", %{conn: conn} do
      cluster!()

      {:ok, view, _html} = live(conn, "/admin/storage-requests")
      render_click(view, "open-request", %{"id" => Ash.UUID.generate()})

      assert render(view) =~ "That request is gone."
    end
  end

  # -- writes ---------------------------------------------------------------

  describe "approve" do
    test "grows the PVC online and lands applied", %{conn: conn, admin: admin} do
      user = user!()
      cluster!()
      fund_org!(user)
      instance = instance!(version!(), user, running: true)
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      stub_growth!(150, 10)

      {:ok, view, _html} = live(conn, "/admin/storage-requests")
      open!(view, request.id)

      refute has_element?(view, "[data-testid='admin-storage-request-approve-blocker']")
      render_click(view, "approve", %{"id" => request.id})

      assert render(view) =~ "Applied — 150 GB on #{instance.name}."

      # The Requested filter's row leaves; the decision moved.
      refute has_element?(view, "[data-testid='admin-storage-requests-instance-#{request.id}']")

      assert %{status: :applied, decided_by_user_id: decided_by} =
               Ash.get!(StorageRequest, request.id, authorize?: false)

      assert decided_by == admin.id
      assert %{storage_gb: 150} = Ash.get!(Instance, instance.id, authorize?: false)

      # The All view still shows the applied row, and its detail keeps the
      # decision's stamps.
      render_click(view, "filter-status", %{"status" => ""})
      open!(view, request.id)

      assert text_of(view, "[data-testid='admin-storage-request-status']") == "Applied"
      assert render(view) =~ "Applied"
    end

    test "a failed apply in the queue leaves Approved with the error and Retry", %{
      conn: conn
    } do
      user = user!()
      cluster!()
      fund_org!(user)
      instance = instance!(version!(), user, running: true)
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      stub(ResourceQuota, :create, fn _kc, _ns, "app-quota", _spec -> {:ok, %{}} end)

      stub(PersistentVolumeClaim, :get, fn _kc, _ns, "app-data" ->
        {:ok, %{"spec" => %{"resources" => %{"requests" => %{"storage" => "10Gi"}}}}}
      end)

      stub(PersistentVolumeClaim, :upsert, fn _kc, _ns, "app-data", _spec ->
        {:error, %Error{reason: :api_error, message: "the API server refused the patch"}}
      end)

      {:ok, view, _html} = live(conn, "/admin/storage-requests")
      open!(view, request.id)
      render_click(view, "approve", %{"id" => request.id})

      assert render(view) =~ "The decision is recorded, but the volume patch failed"
      assert %{status: :approved} = Ash.get!(StorageRequest, request.id, authorize?: false)

      # The row moved to Approved; its error rides the row and the detail's
      # Retry is the next lever — never a second decision.
      render_click(view, "filter-status", %{"status" => "approved"})

      assert text_of(view, "[data-testid='admin-storage-requests-error-#{request.id}']") =~
               "the API server refused the patch"

      open!(view, request.id)
      assert has_element?(view, "[data-testid='admin-storage-request-retry']")
    end

    test "an approved row with no error reads as the pending apply", %{conn: conn, admin: admin} do
      user = user!()
      cluster!()
      fund_org!(user)
      instance = instance!(version!(), user, running: true)
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      # The crash window: the durable decision landed, the apply did not
      # run. The queue must say so and offer the retry, not a re-decision.
      {:ok, _approved} = StorageRequest.approve(request, %{}, actor: admin)

      {:ok, view, _html} = live(conn, "/admin/storage-requests")
      render_click(view, "filter-status", %{"status" => "approved"})
      open!(view, request.id)

      assert render(view) =~ "The decision is recorded; the volume patch has not run yet."
      assert has_element?(view, "[data-testid='admin-storage-request-retry']")
    end

    test "a failed apply leaves the decision durable and Retry converges", %{
      conn: conn,
      admin: admin
    } do
      user = user!()
      cluster!()
      fund_org!(user)
      instance = instance!(version!(), user, running: true)
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      stub(ResourceQuota, :create, fn _kc, _ns, "app-quota", _spec -> {:ok, %{}} end)

      stub(PersistentVolumeClaim, :get, fn _kc, _ns, "app-data" ->
        {:ok, %{"spec" => %{"resources" => %{"requests" => %{"storage" => "10Gi"}}}}}
      end)

      stub(PersistentVolumeClaim, :upsert, fn _kc, _ns, "app-data", _spec ->
        {:error, %Error{reason: :api_error, message: "the API server refused the patch"}}
      end)

      # The approve decision + a failed apply, through the operation (the
      # queue's retry precondition).
      assert {:ok, %StorageRequest{status: :approved} = failed} =
               Infrastructure.approve_storage_request(admin, request.id)

      assert failed.apply_error =~ "the API server refused the patch"

      {:ok, view, _html} = live(conn, "/admin/storage-requests")
      render_click(view, "filter-status", %{"status" => "approved"})
      open!(view, request.id)

      assert text_of(view, "[data-testid='admin-storage-request-apply-error']") =~
               "the API server refused the patch"

      assert has_element?(view, "[data-testid='admin-storage-request-retry']")

      # The retry can fail again — the decision stays, the error refreshes.
      render_click(view, "retry", %{"id" => request.id})
      assert render(view) =~ "The retry did not land"
      assert %{status: :approved} = Ash.get!(StorageRequest, request.id, authorize?: false)

      # The cluster recovers: the retry converges and marks it applied.
      stub(PersistentVolumeClaim, :upsert, fn _kc, _ns, "app-data", spec ->
        assert spec.size == "150Gi"
        {:ok, %{}}
      end)

      render_click(view, "retry", %{"id" => request.id})
      assert render(view) =~ "Applied — 150 GB on #{instance.name}."

      assert %{status: :applied, apply_error: nil} =
               Ash.get!(StorageRequest, request.id, authorize?: false)

      assert %{storage_gb: 150} = Ash.get!(Instance, instance.id, authorize?: false)
    end
  end

  describe "reject" do
    test "requires feedback and records it for the member", %{conn: conn} do
      user = user!()
      cluster!()
      instance = instance!(version!(), user)
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      {:ok, view, _html} = live(conn, "/admin/storage-requests")
      open!(view, request.id)

      form = "#admin-storage-request-reject-#{request.id}"

      view
      |> element(form)
      |> render_submit(%{"reject" => %{"id" => request.id, "feedback" => "   "}})

      assert render(view) =~ "Feedback is required"
      assert %{status: :requested} = Ash.get!(StorageRequest, request.id, authorize?: false)

      view
      |> element(form)
      |> render_submit(%{
        "reject" => %{"id" => request.id, "feedback" => "We can't attach that much right now"}
      })

      assert render(view) =~ "Rejected. The customer sees that feedback verbatim."

      assert %{status: :rejected, rejection_reason: "We can't attach that much right now"} =
               Ash.get!(StorageRequest, request.id, authorize?: false)

      # The All filter still shows the terminal row; its detail carries the
      # member-visible feedback.
      render_click(view, "filter-status", %{"status" => ""})
      open!(view, request.id)

      assert text_of(view, "[data-testid='admin-storage-request-rejection']") =~
               "We can't attach that much right now"

      # A second reject against the terminal row is refused, not lost.
      render_click(view, "reject", %{
        "reject" => %{"id" => request.id, "feedback" => "again"}
      })

      assert render(view) =~ "only an open storage request"
    end
  end

  # -- the notification path ------------------------------------------------

  describe "the live badge and queue insert" do
    test "a create broadcast inserts the row and bumps the badge", %{conn: conn} do
      user = user!()
      cluster!()
      instance = instance!(version!(), user)

      {:ok, view, _html} = live(conn, "/admin/storage-requests")

      assert text_of(view, "[data-testid='admin-storage-requests-count-requested']") == "0"
      refute has_element?(view, "[data-testid='admin-pending-storage-requests']")

      request =
        StorageRequestFixtures.request!(instance, user, %{
          requested_gb: 150,
          reason: "Arrived live"
        })

      # No reload: the queue topic's notification re-reads and re-streams.
      assert render(view) =~ "Arrived live"
      assert text_of(view, "[data-testid='admin-pending-storage-requests']") == "1"
      assert text_of(view, "[data-testid='admin-storage-requests-count-requested']") == "1"

      assert has_element?(view, "[data-testid='admin-storage-requests-status-#{request.id}']")

      # A non-queue message is harmless to the chrome hook and the surface.
      send(view.pid, :not_a_queue_notification)
      assert has_element?(view, "[data-testid='admin-storage-requests']")
    end

    test "a stale cursor is not a crash: page one answers under the current filters", %{
      conn: conn
    } do
      user = user!()
      cluster!()
      instance = instance!(version!(), user)

      rows = seed_rejected!(instance, user, 1..2)

      # A cursor Ash refuses (crafted, or one whose window a delete
      # has emptied): the honest answer is page one under the same
      # filter, once.
      {:ok, view, _html} = live(conn, "/admin/storage-requests?status=all&after=not-a-cursor")

      # Page one rides the read's newest-first default.
      seeded_ids = Enum.map(rows, & &1.id)

      assert requests(view) == Enum.reverse(seeded_ids)

      assert text_of(view, "[data-testid='admin-storage-requests-count']") =~
               "Showing 2 entries."
    end

    test "a decision broadcast moves the badge down", %{conn: conn, admin: admin} do
      user = user!()
      cluster!()
      instance = instance!(version!(), user)
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      {:ok, view, _html} = live(conn, "/admin/storage-requests")
      assert text_of(view, "[data-testid='admin-pending-storage-requests']") == "1"

      {:ok, _rejected} =
        Infrastructure.reject_storage_request(admin, request.id, "Not attachable here")

      assert render(view) =~ "No requests waiting."
      refute has_element?(view, "[data-testid='admin-pending-storage-requests']")
    end

    test "pending_count without an actor is zero" do
      assert AdminChrome.pending_count(nil) == 0
    end

    test "pending_count for a demoted actor is zero, not a crashed admin page" do
      assert AdminChrome.pending_count(user!()) == 0
    end
  end

  # -- the gate -------------------------------------------------------------

  describe "the demotion window" do
    test "a mid-session demotion cannot approve or reject", %{conn: conn, admin: admin} do
      user = user!()
      cluster!()
      fund_org!(user)
      instance = instance!(version!(), user, running: true)
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      {:ok, view, _html} = live(conn, "/admin/storage-requests")
      open!(view, request.id)
      assert has_element?(view, "[data-testid='admin-storage-request-approve']")

      # Demote under the live session. User carries no role-write action,
      # so this precondition rides the data layer directly (the wallet
      # suite's own demotion-window idiom).
      query = from(u in "users", where: u.id == ^Ecto.UUID.dump!(admin.id))
      {1, nil} = FluxVale.Repo.update_all(query, set: [platform_role: "user"])

      render_click(view, "approve", %{"id" => request.id})
      assert render(view) =~ "Your admin access ended."
      assert %{status: :requested} = Ash.get!(StorageRequest, request.id, authorize?: false)

      render_click(view, "reject", %{
        "reject" => %{"id" => request.id, "feedback" => "No"}
      })

      assert render(view) =~ "Your admin access ended."
      assert %{status: :requested} = Ash.get!(StorageRequest, request.id, authorize?: false)

      render_click(view, "retry", %{"id" => request.id})
      assert render(view) =~ "Your admin access ended."
      assert %{status: :requested} = Ash.get!(StorageRequest, request.id, authorize?: false)
    end

    test "a demoted admin's open tab freezes: a queue notification refreshes nothing",
         %{conn: conn, admin: admin} do
      user = user!()
      cluster!()
      version = version!()
      fund_org!(user)
      first = instance!(version, user, running: true, name: "Archive box")
      first_request = StorageRequestFixtures.request!(first, user, %{requested_gb: 150})

      {:ok, view, _html} = live(conn, "/admin/storage-requests")

      # Pre-demotion the page is live: a create broadcasts on the
      # queue topic and the row lands without any click.
      second = instance!(version, user, running: true, name: "Video box")
      second_request = StorageRequestFixtures.request!(second, user, %{requested_gb: 120})

      assert has_element?(
               view,
               "[data-testid='admin-storage-requests-rate-#{first_request.id}']"
             )

      assert has_element?(
               view,
               "[data-testid='admin-storage-requests-rate-#{second_request.id}']"
             )

      # Demote under the live session (the idiom above).
      query = from(u in "users", where: u.id == ^Ecto.UUID.dump!(admin.id))
      {1, nil} = FluxVale.Repo.update_all(query, set: [platform_role: "user"])

      # A THIRD request broadcasts while the session is dead: the
      # AdminDemotionGate info gate halts the notification before the
      # surface's refresh ever runs — the row never reaches the
      # stream. The tab is quiet, not live.
      third = instance!(version, user, running: true, name: "Cold box")
      third_request = StorageRequestFixtures.request!(third, user, %{requested_gb: 180})

      refute has_element?(
               view,
               "[data-testid='admin-storage-requests-rate-#{third_request.id}']"
             )

      # The next explicit event names the session honestly.
      render_click(view, "filter-status", %{"status" => "requested"})
      assert render(view) =~ "Your admin access ended."
    end
  end

  # The capped test's row ids, in render order (the rate cell shares the
  # request id and never collides with the status filter's testid).
  defp requests(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-testid^='admin-storage-requests-rate-']")
    |> Enum.map(fn node ->
      [testid] = LazyHTML.attribute(node, "data-testid")
      String.replace_prefix(testid, "admin-storage-requests-rate-", "")
    end)
  end
end
