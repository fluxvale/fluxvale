defmodule FluxValeWeb.EdgeWakeControllerTest do
  @moduledoc false

  # The wake endpoint's decision table (#203, ADR-0036) — every arm of
  # answer/2 plus the probe and not-found guards. K8s applies are
  # Mimic-stubbed; the assertions are the HTTP shapes a visitor, an
  # API client, and a monitor each see.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.TestSupport.InstanceFixtures

  # Plug wants lowercase header keys; EdgeRoutes names the canonical
  # casing — normalized in one place.
  @header String.downcase(EdgeRoutes.instance_header())

  defp user do
    User.create!("wakepage-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp instance!(status, fund \\ true) do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    created =
      Instance.create!(
        %{name: "App", app_version_id: version.id, env_vars: %{}},
        actor: user()
      )

    instance =
      created
      |> InstanceFixtures.pin!(
        namespace: "fluxvale-app-#{created.id}",
        deployed_at: DateTime.utc_now()
      )
      |> InstanceFixtures.walk_to!(status)

    unless fund, do: drain_org!(instance)

    instance
  end

  # The org starts with the JIT welcome grant (#122); an unfunded org
  # is a drained one (posting never checks balance, drains overshoot).
  defp drain_org!(instance) do
    org = Ash.get!(Organization, instance.organization_id, authorize?: false)

    case Billing.ensure_wallet(org) do
      {:ok, wallet} ->
        {:ok, balance_cents} = Billing.balance(wallet, authorize?: false)

        if balance_cents > 0 do
          # cents → micro-cents (the wallet's unit).
          Billing.debit_wallet(wallet, balance_cents * 10_000)
        end

      _no_wallet ->
        :ok
    end

    :ok
  end

  defp stub_k8s do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
  end

  defp browser(conn) do
    conn
    |> put_req_header("accept", "text/html,application/xhtml+xml")
    |> put_req_header("user-agent", "Mozilla/5.0 (X11; Linux x86_64)")
  end

  test "a sleeping instance wakes and serves the interstitial to a browser", %{conn: conn} do
    stub_k8s()
    instance = instance!(:sleeping)

    conn =
      conn
      |> browser()
      |> put_req_header(@header, instance.id)
      |> get("/_fluxvale_edge/edge-wake-path")

    body = html_response(conn, 200)
    assert body =~ "Waking"
    assert body =~ ~s(http-equiv="refresh")

    waking = Instance.get_by_id!(instance.id, authorize?: false)
    assert waking.status == :starting
  end

  test "a sleeping instance wakes a machine client with 503 + Retry-After", %{conn: conn} do
    stub_k8s()
    instance = instance!(:sleeping)

    conn =
      conn
      |> put_req_header("user-agent", "curl/8.5.0")
      |> put_req_header(@header, instance.id)
      |> get("/_fluxvale_edge/edge-wake-path")

    assert response(conn, 503)
    assert get_resp_header(conn, "retry-after") == ["3"]

    waking = Instance.get_by_id!(instance.id, authorize?: false)
    assert waking.status == :starting
  end

  test "an unfunded sleeping instance stays asleep — plainly", %{conn: conn} do
    stub_k8s()
    instance = instance!(:sleeping, false)

    conn =
      conn
      |> browser()
      |> put_req_header(@header, instance.id)
      |> get("/_fluxvale_edge/edge-wake-path")

    assert response(conn, 503) =~ "top-up"

    slept = Instance.get_by_id!(instance.id, authorize?: false)
    assert slept.status == :sleeping
  end

  test "a probe never wakes a sleeping instance — it reads 503", %{conn: conn} do
    stub_k8s()
    instance = instance!(:sleeping)

    conn =
      conn
      |> put_req_header("user-agent", "UptimeRobot/2.0")
      |> put_req_header(@header, instance.id)
      |> get("/_fluxvale_edge/edge-wake-path")

    assert response(conn, 503) == "asleep"

    slept = Instance.get_by_id!(instance.id, authorize?: false)
    assert slept.status == :sleeping
  end

  test "a :starting instance gets the page without re-triggering", %{conn: conn} do
    stub_k8s()
    instance = instance!(:sleeping)

    conn =
      conn
      |> browser()
      |> put_req_header(@header, instance.id)
      |> get("/_fluxvale_edge/edge-wake-path")

    assert html_response(conn, 200) =~ "Waking"

    # The meta-refresh poll: still :starting, still the page.
    poll =
      build_conn()
      |> browser()
      |> put_req_header(@header, instance.id)
      |> get("/_fluxvale_edge/edge-wake-path")

    assert html_response(poll, 200) =~ "Waking"
  end

  test "a :running instance restores the serving edge and redirects", %{conn: conn} do
    stub_k8s()
    instance = instance!(:running)

    expect(Ingress, :create, fn _kc, _ns, "app-ingress", spec ->
      assert spec.service_name == "app"
      {:ok, %{}}
    end)

    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

    conn =
      conn
      |> browser()
      |> put_req_header(@header, instance.id)
      |> get("/_fluxvale_edge/edge-wake-path?keep=1")

    assert redirected_to(conn) == "/edge-wake-path?keep=1"

    # The found-status interstitial: the one HTML body :found renders.
    assert response(conn, 302) =~ "Ready"
  end

  test "a non-serving state answers 503 plainly", %{conn: conn} do
    stub_k8s()
    instance = instance!(:running)
    {:ok, stopped} = Instance.stop(instance, authorize?: false)

    conn =
      conn
      |> browser()
      |> put_req_header(@header, stopped.id)
      |> get("/_fluxvale_edge/edge-wake-path")

    assert response(conn, 503) =~ "serving requests"
  end

  test "a failed serving-route restore serves the retry hint, not a crash", %{conn: conn} do
    stub_k8s()
    instance = instance!(:running)

    expect(Ingress, :create, fn _kc, _ns, "app-ingress", _spec ->
      {:error, Error.connection_error("routes refused")}
    end)

    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

    conn =
      conn
      |> browser()
      |> put_req_header(@header, instance.id)
      |> get("/_fluxvale_edge/edge-wake-path")

    assert response(conn, 503) =~ "retrying the switch"
  end

  # Through the real endpoint dispatch: the EdgeHost plug rewrites a
  # MARKED instance-host request (arbitrary path, query kept) onto the
  # wake route — the exact shape a sleeping instance's visitor
  # produces (the marker middleware is on every wake-mode route).
  test "an instance-host request rides the EdgeHost rewrite end to end", %{conn: conn} do
    stub_k8s()
    instance = instance!(:running)

    expect(Ingress, :create, fn _kc, _ns, "app-ingress", _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

    conn =
      %{conn | host: "#{instance.slug}.fluxvale.lvh.me"}
      |> browser()
      |> put_req_header(@header, instance.id)
      |> get("/deeply/nested/path?keep=1")

    assert redirected_to(conn) == "/deeply/nested/path?keep=1"
  end

  test "no marker header is a 404; so is an unknown instance", %{conn: conn} do
    stub_k8s()

    assert response(get(conn, "/_fluxvale_edge/edge-wake-path"), 404)

    ghost = "00000000-0000-7000-8000-000000000000"

    ghost_conn =
      build_conn()
      |> put_req_header(@header, ghost)
      |> get("/_fluxvale_edge/edge-wake-path")

    assert response(ghost_conn, 404)
  end
end
