defmodule FluxValeWeb.InstanceLive.StorageRequestTest do
  @moduledoc """
  #250 S4: the member storage-request row on the instance page — the
  boundary, the inline form (target, reason, live projected rate), the
  live decision card (requested/approved/rejected/applied), and the S2
  action as the server-side authority.
  """

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveViewTest

  alias FluxVale.Catalog.AppVersion.SetSortKey
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.StorageClass
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.StorageRequest
  alias FluxVale.Pricing
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers
  alias FluxVale.TestSupport.StorageRequestFixtures

  setup %{conn: conn} do
    {user, conn} = SessionHelpers.user_with_session(conn)
    version = InstanceFixtures.app_version!(default_storage_gb: 10)
    InstanceFixtures.local_cluster!()
    {:ok, user: user, conn: conn, version: version}
  end

  @max_gb 7_600

  describe "the storage row" do
    test "states the allocation and the self-service boundary", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user, :running)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid='storage-card']")

      assert has_element?(
               view,
               "[data-testid='storage-allocation']",
               "10 GB · self-service up to 100 GB"
             )

      assert has_element?(view, "[data-testid='storage-request-open']", "Request more")
      refute has_element?(view, "#storage-request-form")
    end

    test "hides the request affordance for the states that can't ask", %{
      conn: conn,
      user: user,
      version: version
    } do
      # :pending — setup isn't finished, and the create would refuse it
      # anyway; deleting/lost are the plan's explicit hides.
      pending = instance!(version, user, :pending)
      {:ok, pending_view, _html} = live(conn, ~p"/instances/#{pending.id}")
      refute has_element?(pending_view, "[data-testid='storage-request-open']")

      {:ok, deleting_row} = InstanceK8s.update_status(pending, :deleting, "Tearing down")
      {:ok, deleting_view, _html} = live(conn, ~p"/instances/#{deleting_row.id}")
      assert has_element?(deleting_view, "[data-testid='storage-card']")
      refute has_element?(deleting_view, "[data-testid='storage-request-open']")

      running = instance!(version, user, :running)
      {:ok, lost_row} = InstanceK8s.update_status(running, :lost, "Namespace gone")
      {:ok, lost_view, _html} = live(conn, ~p"/instances/#{lost_row.id}")
      refute has_element?(lost_view, "[data-testid='storage-request-open']")
    end

    test "at the attachable ceiling there is no form to open", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user, :running, %{storage_gb: @max_gb})
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid='storage-at-max']")
      refute has_element?(view, "[data-testid='storage-request-open']")
    end
  end

  describe "the request form" do
    test "opens with the boundary's minimum, the ceiling, and the current context", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user, :stopped)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      open_form(view)

      assert has_element?(view, "#storage-request-form")

      assert has_element?(
               view,
               "[data-testid='storage-request-context']",
               "Currently 10 GB · self-service up to 100 GB"
             )

      target = render(element(view, "#storage_request_requested_gb"))
      assert target =~ ~s(min="101")
      assert target =~ ~s(max="7600")
      assert target =~ ~s(step="1")
      assert target =~ ~s(type="number")

      reason = render(element(view, "#storage_request_reason"))
      assert reason =~ ~s(maxlength="280")
    end

    test "prices the target live through the apply's own snapshot choice", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user, :running)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      open_form(view)

      view
      |> element("#storage-request-form")
      |> render_change(%{"storage_request" => %{"requested_gb" => "150", "reason" => ""}})

      {:ok, %{running_cents: cents}} =
        Infrastructure.resize_preview(instance, %{
          cpu_cores: instance.cpu_cores,
          memory_mb: instance.memory_mb,
          storage_gb: 150
        })

      assert has_element?(
               view,
               "[data-testid='storage-request-price']",
               Pricing.format_monthly_rate(cents)
             )

      assert has_element?(
               view,
               "[data-testid='storage-request-price']",
               "the rate is confirmed when it's approved"
             )
    end

    test "an unpriced target promises no guess", %{conn: conn, user: user} do
      # States actions can't produce: the pre-#125 sizeless version
      # (the resize panel's repair-shape fixture), where the preview is
      # `{:ok, nil}` — the form says the price is confirmed at approval.
      version = unsized_version!()
      instance = instance!(version, user, :running, %{storage_gb: 10})
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      open_form(view)

      assert has_element?(view, "[data-testid='storage-request-price-unpriced']")

      assert has_element?(
               view,
               "[data-testid='storage-request-price']",
               "Price confirmed at approval"
             )

      # The created request carries the same advisory no-number: its
      # card states the price is confirmed at approval.
      submit(view, "150", "A reason")

      assert has_element?(
               view,
               "[data-testid='storage-request-quote']",
               "Price confirmed at approval"
             )
    end

    test "a bad target keeps the form and shows no number", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user, :running)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      open_form(view)

      view
      |> element("#storage-request-form")
      |> render_change(%{"storage_request" => %{"requested_gb" => "lots", "reason" => ""}})

      assert has_element?(view, "[data-testid='storage-request-price-unpriced']")
    end

    test "submits through the action and lands the status card", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user, :running)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      open_form(view)
      submit(view, "150", "  Need room for archives  ")

      assert render(view) =~ "Request sent"

      assert has_element?(view, "[data-testid='storage-request-status']")
      assert has_element?(view, "[data-testid='storage-request-target']", "150 GB total")
      assert has_element?(view, "[data-testid='storage-request-target']", "from 10 GB")
      assert has_element?(view, "[data-testid='storage-request-status-badge']", "Awaiting review")
      assert has_element?(view, "[data-testid='storage-request-submitted']", "Requested")
      refute has_element?(view, "#storage-request-form")

      # The row is the action's: trimmed reason, snapshot current, and
      # the quote the form showed.
      assert [request] = requests!(instance, user)
      assert request.reason == "Need room for archives"
      assert request.current_storage_gb == 10

      assert has_element?(
               view,
               "[data-testid='storage-request-quote']",
               Pricing.format_monthly_rate(request.quoted_monthly_cents)
             )
    end

    test "cancel closes the form without a write", %{conn: conn, user: user, version: version} do
      instance = instance!(version, user, :running)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      open_form(view)
      render_click(view, "storage-request-cancel", %{})

      refute has_element?(view, "#storage-request-form")
      assert has_element?(view, "[data-testid='storage-request-open']")
      assert requests!(instance, user) == []
    end
  end

  describe "the action is the authority" do
    test "a within-boundary target routes to the resize panel", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user, :running)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      open_form(view)
      submit(view, "50", "A small bump")

      assert has_element?(
               view,
               "[data-testid='storage-request-within']",
               "within self-service"
             )

      assert has_element?(view, "#storage-request-form")
      assert requests!(instance, user) == []
    end

    test "a blank reason shows the resource's required copy", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user, :running)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      open_form(view)
      submit(view, "150", "")

      assert has_element?(view, "[data-testid='storage-request-error']", "Reason is required.")
      assert has_element?(view, "#storage-request-form")
    end

    test "a non-numeric target shows the resource's invalid copy", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user, :running)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      open_form(view)
      submit(view, "many", "A reason")

      assert has_element?(view, "[data-testid='storage-request-error']", "Target size is invalid")
    end

    test "a target above the attachable ceiling shows the resource's maximum", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user, :running)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      open_form(view)

      # 8,000 fits the attribute's bigint-safety bound but not the
      # configured ceiling; 11,000 trips the attribute's own max — both
      # are the action's words, interpolated plainly.
      submit(view, "8000", "A reason")

      assert has_element?(
               view,
               "[data-testid='storage-request-error']",
               "exceeds the 7600 GB maximum"
             )

      submit(view, "11000", "A reason")

      assert has_element?(
               view,
               "[data-testid='storage-request-error']",
               "Target size must be less than or equal to 10240"
             )
    end

    test "a reason over 280 shows the resource's length copy", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user, :running)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      open_form(view)
      submit(view, "150", String.duplicate("x", 281))

      assert has_element?(
               view,
               "[data-testid='storage-request-error']",
               "Reason length must be less than or equal to 280"
             )
    end

    test "a second submit after an open request lands shows the open-request copy", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user, :running)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      # The interleaving the index defends: a request landed after this
      # form opened, so the advisory read that validated this submit saw
      # none. The real create answers the S2 refusal; the page re-reads
      # and the status card wins.
      StorageRequestFixtures.request!(instance, user)
      render(view)

      render_click(view, "storage-request-open", %{})

      submit(view, "200", "A bigger request")

      assert render(view) =~ "already has an open storage request"
      assert has_element?(view, "[data-testid='storage-request-status']")
      refute has_element?(view, "#storage-request-form")
    end

    test "an unexpected failure still says something true", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user, :running)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      open_form(view)

      stub(StorageRequest, :request, fn _attrs, _opts -> {:error, :boom} end)

      submit(view, "150", "A reason")

      assert has_element?(view, "[data-testid='storage-request-error']", "Something went wrong")
    end
  end

  describe "the decision card" do
    test "an open request replaces the form", %{conn: conn, user: user, version: version} do
      instance = instance!(version, user, :running)
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid='storage-request-status']")
      assert has_element?(view, "[data-testid='storage-request-status-badge']", "Awaiting review")
      assert has_element?(view, "[data-testid='storage-request-target']", "150 GB total")
      assert has_element?(view, "[data-testid='storage-request-submitted']", "Requested")
      refute has_element?(view, "[data-testid='storage-request-open']")
      refute has_element?(view, "#storage-request-form")

      assert has_element?(
               view,
               "[data-testid='storage-request-quote']",
               Pricing.format_monthly_rate(request.quoted_monthly_cents)
             )
    end

    test "an approved request states the decision", %{conn: conn, user: user, version: version} do
      stub_storage_probe(true)
      instance = instance!(version, user, :running)
      request = StorageRequestFixtures.request!(instance, user)
      admin = AccountsFixtures.platform_admin!()
      {:ok, _approved} = StorageRequest.approve(request, %{}, actor: admin)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid='storage-request-status-badge']", "Approved")

      assert has_element?(
               view,
               "[data-testid='storage-request-approved-copy']",
               "The rate is confirmed when the space is added"
             )

      # No advisory quote once the decision exists, and no future-tense
      # "confirmed at approval" on the card.
      refute has_element?(view, "[data-testid='storage-request-quote']")

      refute render(element(view, "[data-testid='storage-request-status']")) =~
               "confirmed when it's approved"
    end

    test "an approved request whose apply stalled says it is retrying", %{
      conn: conn,
      user: user,
      version: version
    } do
      stub_storage_probe(true)
      instance = instance!(version, user, :running)
      request = StorageRequestFixtures.request!(instance, user)
      admin = AccountsFixtures.platform_admin!()
      {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)

      {:ok, _stalled} =
        StorageRequest.mark_apply_failed(approved, %{error: "pvc patch timed out"},
          authorize?: false
        )

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid='storage-request-status-badge']", "Approved")
      assert has_element?(view, "[data-testid='storage-request-apply-retry']", "we're retrying")
      refute has_element?(view, "[data-testid='storage-request-quote']")
    end

    test "a rejected request shows the feedback verbatim and offers another", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user, :running)
      request = StorageRequestFixtures.request!(instance, user)
      admin = AccountsFixtures.platform_admin!()

      feedback = "Capacity isn't available on your box yet."

      {:ok, _rejected} =
        StorageRequest.reject(request, %{rejection_reason: feedback}, actor: admin)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid='storage-request-rejected']")
      assert has_element?(view, "[data-testid='storage-request-status-badge']", "Not approved")

      assert has_element?(
               view,
               "[data-testid='storage-request-feedback']",
               "Capacity isn't available"
             )

      assert has_element?(view, "[data-testid='storage-request-open']", "Request more")
      refute has_element?(view, "#storage-request-form")
    end

    test "an applied request states the date and the current rate", %{
      conn: conn,
      user: user,
      version: version
    } do
      stub_storage_probe(true)
      instance = instance!(version, user, :running)
      request = StorageRequestFixtures.request!(instance, user)
      admin = AccountsFixtures.platform_admin!()
      {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)
      {:ok, _applied} = StorageRequest.mark_applied(approved, %{}, authorize?: false)

      {:ok, rates} = Pricing.settlement_rates(instance, DateTime.utc_now())

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid='storage-request-applied']")
      assert has_element?(view, "[data-testid='storage-request-status-badge']", "Applied")
      assert has_element?(view, "[data-testid='storage-request-applied-at']", "Applied")

      assert has_element?(
               view,
               "[data-testid='storage-request-applied-rate']",
               "Your current rate is"
             )

      assert has_element?(
               view,
               "[data-testid='storage-request-applied-rate']",
               Pricing.format_monthly_rate(rates.running)
             )

      assert has_element?(view, "[data-testid='storage-request-open']", "Request more")
    end

    test "an applied request on an unpriced row shows no rate and no future tense", %{
      conn: conn,
      user: user
    } do
      stub_storage_probe(true)
      version = unsized_version!()
      instance = instance!(version, user, :running, %{storage_gb: 10})
      request = StorageRequestFixtures.request!(instance, user)
      admin = AccountsFixtures.platform_admin!()
      {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)
      {:ok, _applied} = StorageRequest.mark_applied(approved, %{}, authorize?: false)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid='storage-request-applied']")
      refute has_element?(view, "[data-testid='storage-request-applied-rate']")

      refute render(element(view, "[data-testid='storage-request-applied']")) =~
               "confirmed at approval"
    end

    test "live request writes move the card without a reload", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user, :running)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      open_form(view)

      StorageRequestFixtures.request!(instance, user)
      render(view)

      assert has_element?(view, "[data-testid='storage-request-status']")
      refute has_element?(view, "#storage-request-form")

      admin = AccountsFixtures.platform_admin!()
      {:ok, [request]} = StorageRequest.for_instance(instance.id, actor: user)

      {:ok, _rejected} =
        StorageRequest.reject(request, %{rejection_reason: "Not this time."}, actor: admin)

      render(view)

      assert has_element?(view, "[data-testid='storage-request-rejected']")
      assert has_element?(view, "[data-testid='storage-request-feedback']", "Not this time.")
    end
  end

  describe "crafted and stale events" do
    test "a submit with the form closed applies nothing", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user, :running)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_submit(view, "storage-request-submit", %{
        "storage_request" => %{"requested_gb" => "150", "reason" => "A reason"}
      })

      assert requests!(instance, user) == []
      refute has_element?(view, "[data-testid='storage-request-status']")
    end

    test "unmatched payloads keep the form's state", %{conn: conn, user: user, version: version} do
      instance = instance!(version, user, :running)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      open_form(view)

      render_change(view, "storage-request-change", %{"foo" => "bar"})
      render_submit(view, "storage-request-submit", %{})

      assert has_element?(view, "#storage-request-form")
      assert requests!(instance, user) == []
    end

    test "a submit without a target shows the resource's required copy", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user, :running)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      open_form(view)

      render_submit(view, "storage-request-submit", %{
        "storage_request" => %{"reason" => "A reason"}
      })

      assert has_element?(
               view,
               "[data-testid='storage-request-error']",
               "Target size is required."
             )

      assert has_element?(view, "#storage-request-form")
    end
  end

  test "the member copy stays rate-agnostic in every card state", %{
    conn: conn,
    user: user,
    version: version
  } do
    # The form.
    instance = instance!(version, user, :running)
    {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

    open_form(view)

    view
    |> element("#storage-request-form")
    |> render_change(%{"storage_request" => %{"requested_gb" => "150", "reason" => ""}})

    rate_agnostic!(render(element(view, "[data-testid='storage-card']")))

    # Awaiting review.
    requested = instance!(version, user, :running)
    StorageRequestFixtures.request!(requested, user)
    {:ok, requested_view, _html} = live(conn, ~p"/instances/#{requested.id}")

    rate_agnostic!(render(element(requested_view, "[data-testid='storage-card']")))

    # Rejected.
    rejected = instance!(version, user, :running)
    rejected_request = StorageRequestFixtures.request!(rejected, user)
    admin = AccountsFixtures.platform_admin!()

    {:ok, _rejected} =
      StorageRequest.reject(rejected_request, %{rejection_reason: "No capacity."}, actor: admin)

    {:ok, rejected_view, _html} = live(conn, ~p"/instances/#{rejected.id}")

    rate_agnostic!(render(element(rejected_view, "[data-testid='storage-card']")))

    # Applied.
    stub_storage_probe(true)
    applied = instance!(version, user, :running)
    applied_request = StorageRequestFixtures.request!(applied, user)
    {:ok, approved} = StorageRequest.approve(applied_request, %{}, actor: admin)
    {:ok, _applied} = StorageRequest.mark_applied(approved, %{}, authorize?: false)
    {:ok, applied_view, _html} = live(conn, ~p"/instances/#{applied.id}")

    rate_agnostic!(render(element(applied_view, "[data-testid='storage-card']")))
  end

  # --- helpers ---------------------------------------------------------

  defp rate_agnostic!(card) do
    for term <- ["per GB", "COGS", "vendor", "€", "¢", "cents", "0.03", "3¢"] do
      refute card =~ term
    end
  end

  defp instance!(version, user, status, attrs \\ %{}) do
    params =
      Map.merge(
        %{name: "Storage #{System.unique_integer()}", app_version_id: version.id},
        attrs
      )

    created = Instance.create!(params, actor: user)

    if status == :pending, do: created, else: InstanceFixtures.walk_to!(created, status)
  end

  defp open_form(view) do
    view
    |> element("[data-testid='storage-request-open']")
    |> render_click()
  end

  defp submit(view, target, reason) do
    view
    |> element("#storage-request-form")
    |> render_submit(%{"storage_request" => %{"requested_gb" => target, "reason" => reason}})
  end

  defp requests!(%Instance{} = instance, user) do
    {:ok, requests} = StorageRequest.for_instance(instance.id, actor: user)
    requests
  end

  # The capability probe resolves the cluster's kubeconfig (the resize
  # tests' stub shape); the StorageClass answer is the input under test.
  defp stub_storage_probe(allowed) do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, allowed} end)
  end

  # States actions can't produce: the pre-#125 sizeless version (the
  # resize panel's repair fixture) — its preview is `{:ok, nil}`.
  defp unsized_version! do
    version = InstanceFixtures.app_version!()
    app = Ash.load!(version, :app, authorize?: false).app

    # rem keeps the fabricated version inside the grammar (#700) and
    # one binding keeps version and key the same string.
    seed_version = "0.9.#{rem(System.unique_integer([:positive]), 1000)}"

    Ash.Seed.seed!(FluxVale.Catalog.AppVersion, %{
      version: seed_version,
      sort_key: SetSortKey.key(seed_version),
      image: "test/image:0.9",
      port: 3000,
      app_id: app.id
    })
  end
end
