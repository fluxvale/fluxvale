defmodule FluxValeWeb.AdminStorageRequestsLiveTest do
  @moduledoc """
  The operator storage-request queue (#250, ADR-0046 D5/D6): the live
  list, the status/search filters and the cap, the approval's online grow,
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

      # The Approved chip has nothing yet.
      render_click(view, "filter-status", %{"status" => "approved"})
      assert has_element?(view, "[data-testid='admin-storage-requests-empty']")
      refute render(view) =~ "Archive vault"

      # All brings both back.
      render_click(view, "filter-status", %{"status" => ""})
      assert render(view) =~ "Archive vault"
      assert render(view) =~ "Video exports"

      # The search narrows by the reason (case-insensitive).
      view
      |> element("#admin-storage-requests-search")
      |> render_change(%{"search" => %{"query" => "ARCHIV"}})

      assert render(view) =~ "Archive vault"
      refute render(view) =~ "Video exports"

      # Clearing the search restores the filtered page.
      view
      |> element("#admin-storage-requests-search")
      |> render_change(%{"search" => %{"query" => ""}})

      assert render(view) =~ "Archive vault"
      assert render(view) =~ "Video exports"

      # Requested narrows back to the open rows (both are still open).
      render_click(view, "filter-status", %{"status" => "requested"})
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

    test "the list caps at 100 and says so", %{conn: conn} do
      user = user!()
      cluster!()
      instance = instance!(version!(), user)

      # Bulk closed history the create action deliberately refuses (one
      # open request per instance): Ash.Seed for the cap's volume, each
      # row a distinct clock and a nil advisory quote (the rate's dash).
      created = DateTime.add(DateTime.utc_now(), -10_000, :second)

      for offset <- 1..101 do
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

      {:ok, view, _html} = live(conn, "/admin/storage-requests")
      render_click(view, "filter-status", %{"status" => ""})

      assert has_element?(view, "[data-testid='admin-storage-requests-more']")
      assert render(view) =~ "Showing the latest 100 requests."

      [first_id | _rest] = requests(view)
      assert text_of(view, "[data-testid='admin-storage-requests-rate-#{first_id}']") == "—"
    end

    test "crafted filter/search frames are no-ops", %{conn: conn} do
      user = user!()
      cluster!()
      instance = instance!(version!(), user)
      StorageRequestFixtures.request!(instance, user)

      {:ok, view, _html} = live(conn, "/admin/storage-requests")

      render_click(view, "filter-status", %{"status" => 123})
      render_click(view, "search", %{"search" => %{"query" => 123}})
      render_click(view, "reject", %{"nope" => "x"})

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
