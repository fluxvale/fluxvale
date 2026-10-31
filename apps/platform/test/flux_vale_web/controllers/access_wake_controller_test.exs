defmodule FluxValeWeb.AccessWakeControllerTest do
  @moduledoc false

  # The gateway wake endpoint's decision table (#273, ADR-0039 §6) —
  # the EdgeWake table's mirror with the pairing row as the gate and no
  # redirect (serve owns the routing). K8s applies are Mimic-stubbed;
  # the assertions are the HTTP shapes a visitor, an API client, and a
  # monitor each see through a gateway port.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import ExUnit.CaptureLog

  alias FluxVale.Billing
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    InstanceFixtures.local_cluster!()

    parent = self()

    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    stub(Secret, :create, fn _kc, ns, name, data ->
      send(parent, {:secret_create, ns, name, data})
      {:ok, %{}}
    end)

    stub(PersistentVolumeClaim, :create, fn _kc, _ns, _name, _spec -> {:ok, %{}} end)

    stub(NetworkPolicy, :create, fn _kc, ns, name, spec ->
      send(parent, {:policy_create, ns, name, spec})
      {:ok, %{}}
    end)

    stub(Deployment, :apply_manifest, fn _kc, _manifest -> {:ok, %{}} end)
    # The wake's start lane scales the instance Deployment back up.
    stub(Deployment, :scale, fn _kc, _ns, _name, _replicas -> {:ok, %{}} end)

    # The attach's access-edge limbs and the flip's access arm
    # (ADR-0040 §7) — captured like the secret writes so flip tests can
    # assert on both writes.
    stub(Middleware, :create, fn _kc, _ns, _name, _spec -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, _name, _spec -> {:ok, %{}} end)

    stub(Ingress, :create, fn _kc, _ns, name, spec ->
      send(parent, {:ingress_create, name, spec})
      {:ok, %{}}
    end)

    # The private sleep posture (irrelevant here, but the attach's own
    # converge path tolerates it).
    stub(Ingress, :delete, fn _kc, _ns, _name ->
      {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
    end)

    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, _wallet} = Billing.ensure_wallet(org)
    {:ok, _grant} = Billing.grant_credits(org, 10_000, reason: :adjustment)

    %{org: org, owner: owner}
  end

  defp browser(conn) do
    conn
    |> put_req_header("accept", "text/html,application/xhtml+xml")
    |> put_req_header("user-agent", "Mozilla/5.0 (X11; Linux x86_64)")
  end

  # The full pairing: an :active gateway, a :private instance at the
  # requested status, and the attach between them — every row through
  # the actions.
  defp pair!(org, owner, status) do
    gateway = AccessFixtures.gateway!(org)
    instance = private_at!(org, owner, status)
    {:ok, _route} = Infrastructure.attach_instance(gateway, instance)

    {gateway, instance}
  end

  # A second pairing on the same gateway (one gateway per org — the
  # unique_organization identity).
  defp attach_another!(gateway, org, owner, status) do
    instance = private_at!(org, owner, status)
    {:ok, _route} = Infrastructure.attach_instance(gateway, instance)

    {gateway, instance}
  end

  defp private_at!(org, user, status) do
    version = InstanceFixtures.app_version!()

    created =
      Instance.create!(
        %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: user
      )

    pinned =
      InstanceFixtures.pin!(created,
        namespace: "fluxvale-app-#{created.id}",
        deployed_at: DateTime.utc_now(),
        exposure: :private
      )

    pinned
    |> set_org!(org)
    |> InstanceFixtures.walk_to!(status)
  end

  # The org is the create action's (`SetOrganizationFromActor`); the
  # gateway's org is the test org, so the row is re-pointed the way
  # AccessFixtures does.
  defp set_org!(instance, org) do
    instance
    |> Ash.Changeset.for_update(:update_status, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:organization_id, org.id)
    |> Ash.update!()
  end

  # An org with its own funded wallet and :active gateway (the
  # cross-org 404's other side).
  defp second_org! do
    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, _wallet} = Billing.ensure_wallet(org)
    {:ok, _grant} = Billing.grant_credits(org, 10_000, reason: :adjustment)
    gateway = AccessFixtures.gateway!(org)

    {org, gateway}
  end

  defp set_gateway_state!(gateway, state) do
    gateway
    |> Ash.Changeset.for_update(:update_state, %{state: state}, authorize?: false)
    |> Ash.update!()
  end

  defp wake_url(gateway, instance, path \\ "deep/link"),
    do: "/internal/access/#{gateway.id}/#{instance.id}/#{path}"

  describe "the status table (GET, browser)" do
    test "a sleeping instance wakes and serves the interstitial", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :sleeping)

      conn =
        conn
        |> browser()
        |> get(wake_url(gateway, instance, "repo/settings?x=1"))

      body = html_response(conn, 200)
      assert body =~ "Waking"
      assert body =~ ~s(http-equiv="refresh")
      assert body =~ ~s(content="2")

      waking = Instance.get_by_id!(instance.id, authorize?: false)
      assert waking.status == :starting
    end

    test "an unfunded sleeping instance stays asleep — plainly", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :sleeping)
      drain_org!(instance)

      conn =
        conn
        |> browser()
        |> get(wake_url(gateway, instance))

      assert response(conn, 503) =~ "top-up"

      # The unfunded sleep doesn't resolve on its own: no refresh, and
      # no "keeps checking" copy that would be a lie.
      refute response(conn, 503) =~ "keeps checking"
      refute response(conn, 503) =~ "http-equiv"

      slept = Instance.get_by_id!(instance.id, authorize?: false)
      assert slept.status == :sleeping
    end

    test "a :provisioning gateway's pairing still wakes — the post-resume window", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :sleeping)
      set_gateway_state!(gateway, :provisioning)

      conn =
        conn
        |> browser()
        |> get(wake_url(gateway, instance))

      # Resume lands the row :provisioning for up to the observer's
      # minute, but the pod is already behind the port — the request
      # proves it.
      assert html_response(conn, 200) =~ "Waking"
      assert Instance.get_by_id!(instance.id, authorize?: false).status == :starting
    end

    test "a :needs_attention gateway's pairing still wakes", %{conn: conn, org: org, owner: owner} do
      {gateway, instance} = pair!(org, owner, :sleeping)
      set_gateway_state!(gateway, :needs_attention)

      conn =
        conn
        |> browser()
        |> get(wake_url(gateway, instance))

      assert html_response(conn, 200) =~ "Waking"
      assert Instance.get_by_id!(instance.id, authorize?: false).status == :starting
    end

    test "a :starting instance gets the page without re-triggering", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :starting)

      conn =
        conn
        |> browser()
        |> get(wake_url(gateway, instance))

      assert html_response(conn, 200) =~ "Waking"

      assert Instance.get_by_id!(instance.id, authorize?: false).status == :starting
    end

    test "a :running instance flips the serve config back to the app and keeps the page", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :running)
      drain()

      conn =
        conn
        |> browser()
        |> get(wake_url(gateway, instance))

      # No redirect, ever — the page holds until serve's flipped config
      # answers the next refresh with the app.
      assert html_response(conn, 200) =~ "Waking"
      assert Instance.get_by_id!(instance.id, authorize?: false).status == :running

      # The flip ran during the GET: the regenerated config re-targets
      # the app Service (the row is :running).
      assert_received {:secret_create, _ns, name, %{"serve.json" => json}}
      assert name =~ "serve-config"
      assert json =~ "app.#{instance.namespace}.svc.cluster.local:80"
      refute json =~ "/internal/access/"

      # ADR-0040 §7: the hostname arm flipped too — serving mode on the
      # access entrypoint, one route per hostname row.
      access_routes = drain_access_routes()
      assert access_routes != []

      assert Enum.all?(access_routes, fn spec ->
               spec.entrypoint == "access" and
                 spec.service_name == "app" and
                 spec.middlewares == ["fluxvale-activity"]
             end)
    end

    test "the flip is ONE claim window for BOTH writes — a throttled second GET writes neither",
         %{
           conn: conn,
           org: org,
           owner: owner
         } do
      {gateway, instance} = pair!(org, owner, :running)
      drain()

      first =
        conn
        |> browser()
        |> get(wake_url(gateway, instance))

      assert html_response(first, 200) =~ "Waking"
      assert_received {:secret_create, _ns, _name, %{"serve.json" => _json}}
      assert drain_access_routes() != []

      # The window's one apply-set: the throttled refresh writes neither
      # the serve config nor the access arm — an unthrottled GET loop
      # must not become unthrottled K8s writes. The waking page holds.
      second =
        build_conn()
        |> browser()
        |> get(wake_url(gateway, instance))

      assert html_response(second, 200) =~ "Waking"

      refute_received {:secret_create, _ns, _name, %{"serve.json" => _json}}
      assert drain_access_routes() == []
    end

    test "a failed flip logs and still serves the waking page", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :running)
      drain()

      stub(Tailscale, :refresh_routes, fn _gateway -> {:error, :cluster_down} end)

      log =
        capture_log(fn ->
          failed =
            conn
            |> browser()
            |> get(wake_url(gateway, instance))

          # The flip's failure changes nothing for the visitor: the
          # config still targets here, the next window retries — and
          # the operator gets the reason in the log.
          assert html_response(failed, 200) =~ "Waking"
        end)

      assert log =~ "serve-config flip failed"
      assert log =~ instance.id
      assert Instance.get_by_id!(instance.id, authorize?: false).status == :running
    end

    test "an access-arm failure logs and still serves the waking page", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :running)
      drain()

      stub(Ingress, :create, fn _kc, _ns, "access-" <> _tail, _spec ->
        {:error, Error.connection_error("access routes refused")}
      end)

      log =
        capture_log(fn ->
          failed =
            conn
            |> browser()
            |> get(wake_url(gateway, instance))

          # The arm's failure changes nothing for the visitor: the
          # waking page holds, and the next window retries.
          assert html_response(failed, 200) =~ "Waking"
        end)

      assert log =~ "access-route flip failed"
      assert log =~ instance.id
    end

    test "a kubeconfig failure logs the skip and still serves the waking page", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :running)
      drain()

      # The serve-config leg succeeds (its kubeconfig already resolved);
      # the cluster dies before the access arm's own resolution.
      stub(Tailscale, :refresh_routes, fn _gateway -> {:ok, %{}} end)
      stub(K8s, :kubeconfig, fn _ref -> {:error, Error.connection_error("cluster down")} end)

      log =
        capture_log(fn ->
          skipped =
            conn
            |> browser()
            |> get(wake_url(gateway, instance))

          assert html_response(skipped, 200) =~ "Waking"
        end)

      assert log =~ "access-route flip skipped"
      assert log =~ instance.id
    end

    test "the hostname arm applies even when the serve-config limb fails (decoupled limbs)", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :running)
      drain()

      stub(Tailscale, :refresh_routes, fn _gateway -> {:error, :cluster_down} end)

      log =
        capture_log(fn ->
          failed =
            conn
            |> browser()
            |> get(wake_url(gateway, instance))

          # The visitor's page holds either way...
          assert html_response(failed, 200) =~ "Waking"
        end)

      # ...the failed half is named in the log, and the OTHER half still
      # applied — one sick limb must not starve the other.
      assert log =~ "serve-config flip failed"
      assert drain_access_routes() != []
    end

    test "a detach that landed mid-flip writes no arm", %{conn: conn, org: org, owner: owner} do
      {gateway, instance} = pair!(org, owner, :running)
      drain()

      # The pairing re-check reads the row a SECOND time (the gate's own
      # read was the first): it finds the pairing gone — the owner
      # detached between the gate and the arm write.
      stub(AccessRoute, :get_by_pair, fn _gw_id, _inst_id, _opts ->
        n = Process.get(:pair_reads, 0) + 1
        Process.put(:pair_reads, n)

        if n == 1 do
          # The gate's read: the pairing still stands.
          {:ok, AccessRoute.get_by_instance!(instance.id, authorize?: false)}
        else
          # The arm-write's fresh read: detach won.
          {:error, :gone}
        end
      end)

      conn =
        conn
        |> browser()
        |> get(wake_url(gateway, instance))

      assert html_response(conn, 200) =~ "Waking"

      # The serve-config limb flipped (harmless — the config regenerates
      # from the rows), but NO arm write happened: re-minting routes for
      # a dead pairing would strand drift.
      assert drain_access_routes() == []
    end

    test "a second :running GET inside the window throttles the flip, not the page", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :running)
      drain()

      first =
        conn
        |> browser()
        |> get(wake_url(gateway, instance))

      assert html_response(first, 200) =~ "Waking"
      assert_received {:secret_create, _ns, _name, %{"serve.json" => _json}}

      # The window's one apply: the throttled refresh writes nothing —
      # an unthrottled GET loop must not become unthrottled K8s writes —
      # and the waking page holds either way.
      fresh_conn = build_conn()

      second =
        fresh_conn
        |> browser()
        |> get(wake_url(gateway, instance))

      assert html_response(second, 200) =~ "Waking"

      refute_received {:secret_create, _ns, _name, %{"serve.json" => _json}}
    end

    test "the production root shape — no path after the pairing — matches", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :sleeping)

      # Serve joins the visitor's "/" onto the target path: the most
      # common request carries NOTHING after the prefix. The trailing
      # slash is the same empty glob.
      bare =
        conn
        |> browser()
        |> get("/internal/access/#{gateway.id}/#{instance.id}")

      assert html_response(bare, 200) =~ "Waking"

      {^gateway, second_instance} = attach_another!(gateway, org, owner, :sleeping)
      rooted_conn = build_conn()

      rooted =
        rooted_conn
        |> browser()
        |> get("/internal/access/#{gateway.id}/#{second_instance.id}/")

      assert html_response(rooted, 200) =~ "Waking"
    end

    test "a flip that raced a sleep converges with one bounded retry", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :running)
      drain()

      parent = self()

      expect(Tailscale, :refresh_routes, 2, fn gw ->
        assert gw.id == gateway.id

        if Instance.get_by_id!(instance.id, authorize?: false).status == :running do
          # Stage the last-writer race: the row commits :sleeping while
          # the flip's regeneration is in flight, so the write this call
          # would land is the stale app target.
          {:ok, _asleep} = InstanceK8s.update_status(instance, :sleeping, nil)
          send(parent, {:flip, :read_running})
        else
          send(parent, {:flip, :read_sleeping})
        end

        {:ok, %{}}
      end)

      raced =
        conn
        |> browser()
        |> get(wake_url(gateway, instance))

      assert html_response(raced, 200) =~ "Waking"

      # The successful flip re-read the row, saw it moved, and ran the
      # one bounded retry — the regeneration that reads :sleeping.
      assert_received {:flip, :read_running}
      assert_received {:flip, :read_sleeping}
      assert Instance.get_by_id!(instance.id, authorize?: false).status == :sleeping

      # The bounded retry covered BOTH writes (ADR-0040 §7): the access
      # arm re-decided from the fresh row and landed wake mode, not the
      # stale serving one this GET started with.
      access = drain_access_routes()
      assert access != []
      assert Enum.all?(access, &(&1.service_name == "wake"))
    end

    test "a :restoring instance answers the restore copy and never wakes", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :restoring)

      # No wake may happen: any kubeconfig/scale call would be the bug.
      reject(K8s, :kubeconfig, 1)
      reject(Deployment, :scale, 4)

      conn =
        conn
        |> browser()
        |> get(wake_url(gateway, instance))

      body = response(conn, 503)
      assert body =~ "backup restored"
      assert body =~ ~s(content="30")

      assert Instance.get_by_id!(instance.id, authorize?: false).status == :restoring
    end

    test "a non-serving state answers 503 plainly, with a working refresh", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :stopped)

      conn =
        conn
        |> browser()
        |> get(wake_url(gateway, instance))

      body = response(conn, 503)
      assert body =~ "serving requests right now"
      assert body =~ ~s(http-equiv="refresh")
      assert body =~ ~s(content="30")
      assert body =~ "keeps checking"
    end
  end

  describe "machines and probes" do
    test "a machine client gets 503 + Retry-After; the wake still triggers", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :sleeping)

      conn =
        conn
        |> put_req_header("user-agent", "curl/8.5.0")
        |> get(wake_url(gateway, instance))

      assert response(conn, 503) =~ "waking up"
      assert get_resp_header(conn, "retry-after") == ["3"]

      waking = Instance.get_by_id!(instance.id, authorize?: false)
      assert waking.status == :starting
    end

    test "a probe never wakes a sleeping instance — it reads 503", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :sleeping)

      reject(K8s, :kubeconfig, 1)

      conn =
        conn
        |> put_req_header("user-agent", "UptimeRobot/2.0")
        |> get(wake_url(gateway, instance))

      assert response(conn, 503) == "asleep"

      slept = Instance.get_by_id!(instance.id, authorize?: false)
      assert slept.status == :sleeping
    end

    test "a POST wakes but never meta-refreshes — the retryable 503", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :sleeping)

      conn = post(conn, wake_url(gateway, instance), %{"form" => "data"})

      assert response(conn, 503) =~ "resend"
      assert get_resp_header(conn, "retry-after") == ["3"]

      waking = Instance.get_by_id!(instance.id, authorize?: false)
      assert waking.status == :starting
    end

    test "a POST to an unfunded sleep says top-up, not resend", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :sleeping)
      drain_org!(instance)

      conn = post(conn, wake_url(gateway, instance))

      assert response(conn, 503) =~ "top-up"
    end

    test "a POST to a running row flips, then retries", %{conn: conn, org: org, owner: owner} do
      {gateway, instance} = pair!(org, owner, :running)
      drain()

      conn = post(conn, wake_url(gateway, instance))

      assert response(conn, 503) =~ "resend"

      assert_received {:secret_create, _ns, _name, %{"serve.json" => json}}
      assert json =~ "app.#{instance.namespace}.svc.cluster.local:80"
    end

    test "a POST to any other status just retries — no wake, no flip", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :starting)

      reject(K8s, :kubeconfig, 1)

      conn = post(conn, wake_url(gateway, instance))

      assert response(conn, 503) =~ "resend"

      assert Instance.get_by_id!(instance.id, authorize?: false).status == :starting
    end
  end

  describe "the pairing gate (ADR-0039 §6: the row, not the caller)" do
    test "unknown ids 404", %{conn: conn} do
      ghost_gateway = "00000000-0000-7000-8000-000000000001"
      ghost_instance = "00000000-0000-7000-8000-000000000002"

      conn = get(conn, "/internal/access/#{ghost_gateway}/#{ghost_instance}/x")

      assert response(conn, 404) == "not found"
    end

    test "garbage ids read the same 404, never a 500", %{conn: conn} do
      conn = get(conn, "/internal/access/not-a-uuid/also-garbage/x")

      assert response(conn, 404) == "not found"
    end

    test "an existing gateway and instance without a pairing row 404", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      instance = private_at!(org, owner, :sleeping)

      conn = get(conn, wake_url(gateway, instance))

      assert response(conn, 404) == "not found"

      # No pairing, no wake.
      assert Instance.get_by_id!(instance.id, authorize?: false).status == :sleeping
    end

    test "a suspended gateway's pairing 404s — nobody is behind the port", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :sleeping)

      gateway
      |> Ash.Changeset.for_update(:update_state, %{state: :suspended}, authorize?: false)
      |> Ash.update!()

      conn = get(conn, wake_url(gateway, instance))

      assert response(conn, 404) == "not found"
      assert Instance.get_by_id!(instance.id, authorize?: false).status == :sleeping
    end

    test "a public instance behind an out-of-band pairing 404s — the backstop", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      public = AccessFixtures.public_instance!(org, owner)

      # Attach refuses a public instance, so this row can only exist
      # out-of-band — exactly the shape the endpoint's own check is the
      # backstop against (the action-built posture is attach's job).
      AccessRoute.create!(
        %{gateway_id: gateway.id, instance_id: public.id, route_key: "8999"},
        authorize?: false
      )

      conn = get(conn, wake_url(gateway, public))

      assert response(conn, 404) == "not found"
    end

    test "a cross-org pairing 404s — tenant isolation, no leak", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      {_org_b, gateway_b} = second_org!()
      instance_a = private_at!(org, owner, :sleeping)

      # Attach refuses cross-org, so the row is minted directly — the
      # out-of-band shape the endpoint's same-org check backstops.
      AccessRoute.create!(
        %{gateway_id: gateway_b.id, instance_id: instance_a.id, route_key: "8998"},
        authorize?: false
      )

      reject(K8s, :kubeconfig, 1)

      conn = get(conn, wake_url(gateway_b, instance_a))

      assert response(conn, 404) == "not found"
      assert Instance.get_by_id!(instance_a.id, authorize?: false).status == :sleeping
    end

    test "every 404 arm is byte-identical — no posture or existence leak", %{
      org: org,
      owner: owner
    } do
      {gateway, instance} = pair!(org, owner, :sleeping)

      gateway
      |> Ash.Changeset.for_update(:update_state, %{state: :suspended}, authorize?: false)
      |> Ash.update!()

      ghost = "00000000-0000-7000-8000-000000000009"

      arms = [
        get(build_conn(), wake_url(gateway, instance)),
        get(build_conn(), "/internal/access/#{ghost}/#{instance.id}/x"),
        get(build_conn(), "/internal/access/garbage/#{instance.id}/x")
      ]

      assert Enum.all?(arms, &(&1.status == 404))

      bodies = Enum.map(arms, & &1.resp_body)
      assert Enum.uniq(bodies) == ["not found"]
    end
  end

  # The org starts with the JIT welcome grant (#122); an unfunded org
  # is a drained one (posting never checks balance, drains overshoot).
  defp drain_org!(instance) do
    org = Ash.get!(FluxVale.Accounts.Organization, instance.organization_id, authorize?: false)

    case Billing.ensure_wallet(org) do
      {:ok, wallet} ->
        {:ok, balance_cents} = Billing.balance(wallet, authorize?: false)

        if balance_cents > 0 do
          Billing.debit_wallet(wallet, balance_cents * 10_000)
        end

      _no_wallet ->
        :ok
    end

    :ok
  end

  # Everything the setup's capturing stubs hold so far.
  defp drain(acc \\ []) do
    receive do
      {:secret_create, _ns, _name, _data} = msg ->
        drain([msg | acc])

      {:policy_create, _ns, _name, _spec} = msg ->
        drain([msg | acc])

      {:ingress_create, _name, _spec} = msg ->
        drain([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The access-arm routes (the "access-" prefixed IngressRoutes) the
  # capturing stub saw, in arrival order.
  defp drain_access_routes do
    Enum.flat_map(drain(), fn
      {:ingress_create, "access-" <> _tail, spec} -> [spec]
      _other -> []
    end)
  end
end
