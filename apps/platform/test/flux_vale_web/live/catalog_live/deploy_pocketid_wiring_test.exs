defmodule FluxValeWeb.CatalogLive.DeployPocketIdWiringTest do
  @moduledoc false

  # #597 S4: the submit leg — create → wire → deploy! (§4.5). The
  # happy path deploys with the SSO env aboard and a flash naming the
  # client and the PocketID URL; a wiring failure is D3 fail-soft —
  # the created instance parks a choice (deploy without sign-in /
  # retry) and NEVER blocks; a retry converges once the host answers;
  # a ticked submit strips user values under the recipe's env names
  # (belt and braces with the wiring's force_change). PocketID calls
  # are Mimic-stubbed (the ApiClient seam); K8s is stubbed because
  # Oban runs inline — the deploy trigger executes synchronously.

  # Serialized (async: false) on purpose: the detection read pins the
  # PocketID app slug to "pocket-id", and every test here inserts that
  # app — running 9 more concurrent same-slug inserters beside the S2/
  # S3 files tips Postgres's unique-index wait graph into deadlocks
  # (40P01, seen on the first full-suite run). One serialized stream
  # keeps the contention at main's level.
  use FluxValeWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.PocketId.ApiClient
  alias FluxVale.Infrastructure.PocketIdCustody
  alias FluxVale.Infrastructure.PocketIdWiring
  alias FluxVale.Ops.FeatureFlags
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @held_key "held-key-not-a-real-credential"
  @minted_secret "minted-secret-never-logged"
  @issuer "https://id.example"
  @instance_name "Wired Vault"

  @sso_specs %{
    "SSO_AUTHORITY" => %{label: "OIDC issuer URL", type: :string},
    "SSO_CLIENT_ID" => %{label: "OIDC client ID", type: :string},
    "SSO_CLIENT_SECRET" => %{label: "OIDC client secret", type: :string, secret: true},
    "SSO_ENABLED" => %{label: "Enable Pocket ID sign-in", type: :boolean, default: false}
  }

  @schema Map.put(@sso_specs, "SMTP_HOST", %{label: "SMTP host", type: :string})

  @recipe %{
    "kind" => "env",
    "issuer_env" => "SSO_AUTHORITY",
    "client_id_env" => "SSO_CLIENT_ID",
    "client_secret_env" => "SSO_CLIENT_SECRET",
    "enabled_env" => "SSO_ENABLED",
    "pkce" => true
  }

  setup %{conn: conn} do
    # The wizard's ladders are the seeded sizes (deploy_test's setup
    # note) — before the fixtures, same ordering caveat.
    :ok = FluxVale.Seeds.seed_pricing!()

    # The fail-closed gate: on through the real verb.
    :ok = FeatureFlags.enable(:pocketid_sso_wiring, actor: AccountsFixtures.platform_admin!())

    {user, conn} = SessionHelpers.user_with_session(conn)
    InstanceFixtures.local_cluster!()

    pocket_id_version =
      InstanceFixtures.app_version!(app_slug: "pocket-id", configurable_env_vars: %{})

    # S2's audited seam reads the held key from the cluster (stubbed);
    # every K8s call the inline deploy makes is stubbed too.
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    stub(Secret, :get_data, fn _kc, _ns, _ref ->
      {:ok, %{"POCKETID_API_KEY" => @held_key}}
    end)

    stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Secret, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

    version =
      InstanceFixtures.app_version!(
        configurable_env_vars: @schema,
        oidc_wiring: @recipe,
        oidc_callback_path: "/identity/connect/oidc-signin",
        published_at: DateTime.utc_now()
      )

    app = Ash.load!(version, :app, authorize?: false).app

    %{conn: conn, user: user, app: app, version: version, pocket_id_version: pocket_id_version}
  end

  # The active, custody-ready PocketID (S3's shape). The probe stub
  # (completed) rides the caller — each test knows how often step 2
  # renders.
  defp ready_pocketid!(user, pocket_id_version) do
    instance = InstanceFixtures.instance!(pocket_id_version, user)
    running = InstanceFixtures.walk_to!(instance, :running)

    pocketid =
      InstanceFixtures.pin!(running,
        namespace: "fluxvale-app-#{instance.id}",
        deployed_at: ~U[2026-01-01 00:00:00Z]
      )

    PocketIdCustody.record!(
      %{
        organization_id: pocketid.organization_id,
        instance_id: pocketid.id,
        api_key_secret_ref: "fluxvale-pocketid-custody-#{pocketid.id}",
        verified_at: DateTime.utc_now()
      },
      authorize?: false
    )

    pocketid
  end

  defp pocketid_url(pocketid) do
    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)
    "https://#{pocketid.slug}.#{base_domain}"
  end

  # The wiring's green stubs against the chosen PocketID's URL.
  defp green_wiring!(pocketid) do
    url = pocketid_url(pocketid)

    stub(ApiClient, :get_discovery, fn ^url -> {:ok, @issuer} end)

    stub(ApiClient, :create_client, fn ^url, @held_key, attrs ->
      {:ok,
       %{
         client_id: "pid-1",
         client_name: attrs.name,
         secret_id: "sec-1",
         secret: @minted_secret
       }}
    end)
  end

  defp sleeping_pocketid!(pocketid) do
    url = pocketid_url(pocketid)
    stub(ApiClient, :get_discovery, fn ^url -> {:error, :unreachable} end)
  end

  defp open_wizard(conn, app), do: live(conn, ~p"/apps/#{app.slug}/deploy")

  defp to_ticked_step_2(view, version) do
    view
    |> element("#version-#{version.id}")
    |> render_click()

    view
    |> element("button[phx-click='to-env']")
    |> render_click()

    view
    |> element("#pocketid-offer-check")
    |> render_click()
  end

  defp to_step_4(view, env \\ %{"SMTP_HOST" => "smtp.example"}) do
    view
    |> element("#env-form")
    |> render_submit(%{env_values: env})

    view
    |> form("#resources-form")
    |> render_submit()

    view
  end

  defp submit(view, name \\ @instance_name) do
    view
    |> form("#deploy-form", instance: %{name: name})
    |> render_submit()
  end

  # The user's APP instance (their org also holds the PocketID the
  # fixtures built — list_for_actor returns both).
  defp created!(user, version) do
    owned = Instance.list_for_actor!(actor: user)
    app_instance = Enum.find(owned, &(&1.app_version_id == version.id))
    Instance.get_by_id!(app_instance.id, actor: user)
  end

  describe "the happy path — wired, then deployed" do
    test "a ticked offer wires between create and deploy; the flash names the client", %{
      conn: conn,
      user: user,
      app: app,
      version: version,
      pocket_id_version: pocket_id_version
    } do
      pocketid = ready_pocketid!(user, pocket_id_version)
      expect(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 404}} end)
      green_wiring!(pocketid)

      {:ok, view, _html} = open_wizard(conn, app)
      to_ticked_step_2(view, version)
      to_step_4(view)
      submit(view)

      assert_redirect(view)

      instance = created!(user, version)

      # Deployed through the inline trigger, with the SSO env aboard.
      assert instance.status == :starting
      assert instance.namespace == "fluxvale-app-#{instance.id}"
      assert instance.env_vars["SSO_AUTHORITY"] == @issuer
      assert instance.env_vars["SSO_CLIENT_ID"] == "pid-1"
      assert instance.env_vars["SSO_CLIENT_SECRET"] == @minted_secret
      assert instance.env_vars["SSO_ENABLED"] == "true"
      assert instance.env_vars["SMTP_HOST"] == "smtp.example"

      # The durable record exists; the secret is nowhere on it.
      wiring = PocketIdWiring.get_by_instance!(instance.id, actor: user)
      assert wiring.pocket_id_client_id == "pid-1"
      refute "#{inspect(wiring)}" =~ @minted_secret
    end

    test "the flash confirms the wiring — client name and Pocket ID URL", %{
      conn: conn,
      user: user,
      app: app,
      version: version,
      pocket_id_version: pocket_id_version
    } do
      pocketid = ready_pocketid!(user, pocket_id_version)
      expect(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 404}} end)
      green_wiring!(pocketid)

      {:ok, view, _html} = open_wizard(conn, app)
      to_ticked_step_2(view, version)
      to_step_4(view)

      # Follow the redirect the submit issued: the flash rides it
      # onto the instance page (follow_redirect replays the flash
      # into the followed conn).
      submitted = submit(view)
      {:ok, _view, html} = follow_redirect(submitted, conn)

      assert html =~ "Pocket ID sign-in wired"
      assert html =~ "FluxVale · #{@instance_name}"
      assert html =~ pocketid_url(pocketid)
    end

    test "an unticked offer deploys exactly as before — no wiring call at all", %{
      conn: conn,
      user: user,
      app: app,
      version: version,
      pocket_id_version: pocket_id_version
    } do
      _pocketid = ready_pocketid!(user, pocket_id_version)
      expect(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 404}} end)

      # Any wiring call would fail the test (Mimic rejects un-stubbed
      # calls): the leg must not run.
      reject(ApiClient, :get_discovery, 1)
      reject(ApiClient, :create_client, 3)

      {:ok, view, _html} = open_wizard(conn, app)

      # To step 2 and straight through — the checkbox stays cold (D7).
      view
      |> element("#version-#{version.id}")
      |> render_click()

      view
      |> element("button[phx-click='to-env']")
      |> render_click()

      to_step_4(view)
      submit(view)

      assert_redirect(view)

      instance = created!(user, version)
      assert instance.status == :starting
      assert instance.env_vars["SSO_AUTHORITY"] == nil
      assert {:error, _none} = PocketIdWiring.get_by_instance(instance.id, actor: user)
    end
  end

  # Terence's explicit ask, end to end: the sleeping PocketID cannot
  # block the deploy — the user chooses, both branches are honest,
  # and a retry converges.
  describe "the wake race (D3 — the choice, never a block)" do
    test "a sleeping PocketID parks the choice; the instance waits, deployable", %{
      conn: conn,
      user: user,
      app: app,
      version: version,
      pocket_id_version: pocket_id_version
    } do
      pocketid = ready_pocketid!(user, pocket_id_version)
      expect(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 404}} end)
      sleeping_pocketid!(pocketid)

      {:ok, view, _html} = open_wizard(conn, app)
      to_ticked_step_2(view, version)
      to_step_4(view)
      submit(view)

      # The choice renders: the reason, both ways out. The submit
      # form is gone (a second create would duplicate the instance).
      assert has_element?(view, "#pocketid-wiring-choice")
      assert has_element?(view, "[data-testid='deploy-without-sso']")
      assert has_element?(view, "[data-testid='retry-pocketid']")
      refute has_element?(view, "#deploy-form")
      assert render(view) =~ "may be waking up"

      # Created, NOT deployed, fully deployable — nothing was lost.
      instance = created!(user, version)
      assert instance.status == :pending
      assert {:error, _none} = PocketIdWiring.get_by_instance(instance.id, actor: user)
    end

    test "\"Deploy without sign-in\" deploys the unwired instance", %{
      conn: conn,
      user: user,
      app: app,
      version: version,
      pocket_id_version: pocket_id_version
    } do
      pocketid = ready_pocketid!(user, pocket_id_version)
      expect(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 404}} end)
      sleeping_pocketid!(pocketid)

      {:ok, view, _html} = open_wizard(conn, app)
      to_ticked_step_2(view, version)
      to_step_4(view)
      submit(view)

      view
      |> element("[data-testid='deploy-without-sso']")
      |> render_click()

      assert_redirect(view)

      instance = created!(user, version)
      assert instance.status == :starting
      assert instance.env_vars["SSO_AUTHORITY"] == nil
      assert {:error, _none} = PocketIdWiring.get_by_instance(instance.id, actor: user)
    end

    test "\"Retry\" re-runs the wiring on the created instance and converges", %{
      conn: conn,
      user: user,
      app: app,
      version: version,
      pocket_id_version: pocket_id_version
    } do
      pocketid = ready_pocketid!(user, pocket_id_version)
      expect(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 404}} end)
      sleeping_pocketid!(pocketid)

      {:ok, view, _html} = open_wizard(conn, app)
      to_ticked_step_2(view, version)
      to_step_4(view)
      submit(view)

      # PocketID woke: the same choice, retried, now wires and the
      # deploy proceeds as if it had never failed.
      green_wiring!(pocketid)

      {:ok, _view, html} =
        view
        |> element("[data-testid='retry-pocketid']")
        |> render_click()
        |> follow_redirect(conn)

      assert html =~ "Pocket ID sign-in wired"

      instance = created!(user, version)
      assert instance.status == :starting
      assert instance.env_vars["SSO_AUTHORITY"] == @issuer

      wiring = PocketIdWiring.get_by_instance!(instance.id, actor: user)
      assert wiring.pocket_id_client_id == "pid-1"
    end

    test "a still-sleeping retry re-parks the choice — the instance still waits", %{
      conn: conn,
      user: user,
      app: app,
      version: version,
      pocket_id_version: pocket_id_version
    } do
      pocketid = ready_pocketid!(user, pocket_id_version)
      expect(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 404}} end)
      sleeping_pocketid!(pocketid)

      {:ok, view, _html} = open_wizard(conn, app)
      to_ticked_step_2(view, version)
      to_step_4(view)
      submit(view)

      view
      |> element("[data-testid='retry-pocketid']")
      |> render_click()

      assert has_element?(view, "#pocketid-wiring-choice")
      assert created!(user, version).status == :pending
    end

    # The panel replaces the form precisely because a second create
    # would duplicate the instance — a crafted save riding the parked
    # window is silence (the crafted-channel posture, the same seam
    # the choice handlers guard).
    test "a crafted save while the choice is parked is silence — no second instance", %{
      conn: conn,
      user: user,
      app: app,
      version: version,
      pocket_id_version: pocket_id_version
    } do
      pocketid = ready_pocketid!(user, pocket_id_version)
      expect(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 404}} end)
      sleeping_pocketid!(pocketid)

      {:ok, view, _html} = open_wizard(conn, app)
      to_ticked_step_2(view, version)
      to_step_4(view)
      submit(view)

      html = render_click(view, "save", %{"instance" => %{"name" => "A duplicate"}})

      # The choice stands, the form is still gone, and nothing
      # navigated — the parked instance is the only path forward.
      assert html =~ "pocketid-wiring-choice"
      refute html =~ "deploy-form"

      owned = Instance.list_for_actor!(actor: user)
      assert [only] = Enum.filter(owned, &(&1.app_version_id == version.id))
      assert only.name == @instance_name
    end

    # The parked window is unbounded: the instance page's own Deploy
    # button (or another tab) may have moved the instance on — the
    # choice must never force a second deploy over a live status.
    test "\"Deploy without sign-in\" after the instance moved on opens it, never re-deploys", %{
      conn: conn,
      user: user,
      app: app,
      version: version,
      pocket_id_version: pocket_id_version
    } do
      pocketid = ready_pocketid!(user, pocket_id_version)
      expect(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 404}} end)
      sleeping_pocketid!(pocketid)

      {:ok, view, _html} = open_wizard(conn, app)
      to_ticked_step_2(view, version)
      to_step_4(view)
      submit(view)

      # The stranded user's documented way out, taken from them: the
      # instance page's Deploy button.
      instance = created!(user, version)
      InstanceFixtures.walk_to!(instance, :running)

      {:ok, _view, html} =
        view
        |> element("[data-testid='deploy-without-sso']")
        |> render_click()
        |> follow_redirect(conn)

      assert html =~ "already running"

      moved_on = created!(user, version)
      assert moved_on.status == :running
      assert moved_on.namespace == instance.namespace
    end

    # The window's other exit: delete hard-deletes a never-deployed
    # instance — the choice flashes it and points at a new deploy,
    # never crashes.
    test "\"Deploy without sign-in\" after the instance was deleted flashes, never crashes", %{
      conn: conn,
      user: user,
      app: app,
      version: version,
      pocket_id_version: pocket_id_version
    } do
      pocketid = ready_pocketid!(user, pocket_id_version)
      expect(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 404}} end)
      sleeping_pocketid!(pocketid)

      {:ok, view, _html} = open_wizard(conn, app)
      to_ticked_step_2(view, version)
      to_step_4(view)
      submit(view)

      instance = created!(user, version)
      Ash.destroy!(instance, actor: user)

      {:ok, _view, html} =
        view
        |> element("[data-testid='deploy-without-sso']")
        |> render_click()
        |> follow_redirect(conn)

      assert html =~ "no longer exists"
    end

    # The retry's fresh re-read can find the instance deployed (the
    # same moved-on window): the verdict is its own shape — the panel
    # drops the deploy buttons and offers the instance page instead.
    test "a retry that finds the instance running parks the open-only panel", %{
      conn: conn,
      user: user,
      app: app,
      version: version,
      pocket_id_version: pocket_id_version
    } do
      pocketid = ready_pocketid!(user, pocket_id_version)
      expect(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 404}} end)
      sleeping_pocketid!(pocketid)

      {:ok, view, _html} = open_wizard(conn, app)
      to_ticked_step_2(view, version)
      to_step_4(view)
      submit(view)

      stranded = created!(user, version)
      InstanceFixtures.walk_to!(stranded, :running)

      # PocketID woke too — but the op's fresh read now refuses
      # first: already running, wiring lands with the instance page.
      green_wiring!(pocketid)

      view
      |> element("[data-testid='retry-pocketid']")
      |> render_click()

      assert has_element?(view, "#pocketid-wiring-choice")
      assert render(view) =~ "already running"
      assert has_element?(view, "[data-testid='open-instance']")
      refute has_element?(view, "[data-testid='deploy-without-sso']")
      refute has_element?(view, "[data-testid='retry-pocketid']")

      {:ok, _view, html} =
        view
        |> element("[data-testid='open-instance']")
        |> render_click()
        |> follow_redirect(conn)

      assert html =~ @instance_name
    end

    # The cluster-outage verdict's copy — the key read's K8s error
    # shape, the panel's voice (the API words are the route test's).
    test "a key-store outage parks the choice with the retry copy", %{
      conn: conn,
      user: user,
      app: app,
      version: version,
      pocket_id_version: pocket_id_version
    } do
      pocketid = ready_pocketid!(user, pocket_id_version)
      expect(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 404}} end)

      url = pocketid_url(pocketid)

      stub(ApiClient, :get_discovery, fn ^url -> {:ok, @issuer} end)

      stub(Secret, :get_data, fn _kc, _ns, _ref ->
        {:error, %FluxVale.Clients.K8s.Error{status_code: 500, reason: :unknown, message: "boom"}}
      end)

      {:ok, view, _html} = open_wizard(conn, app)
      to_ticked_step_2(view, version)
      to_step_4(view)
      submit(view)

      assert has_element?(view, "#pocketid-wiring-choice")
      assert render(view) =~ "key store didn&#39;t answer"

      assert created!(user, version).status == :pending
    end

    # The panel's copy follows the operation's reason — the re-paste
    # verdict (401 at the mint) and the honest generic for anything
    # unrecognized both name the way out.
    test "a rejected key parks the choice with the re-paste copy", %{
      conn: conn,
      user: user,
      app: app,
      version: version,
      pocket_id_version: pocket_id_version
    } do
      pocketid = ready_pocketid!(user, pocket_id_version)
      expect(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 404}} end)

      url = pocketid_url(pocketid)

      stub(ApiClient, :get_discovery, fn ^url -> {:ok, @issuer} end)
      stub(ApiClient, :create_client, fn ^url, _key, _attrs -> {:error, :unauthorized} end)

      {:ok, view, _html} = open_wizard(conn, app)
      to_ticked_step_2(view, version)
      to_step_4(view)
      submit(view)

      assert has_element?(view, "#pocketid-wiring-choice")
      assert render(view) =~ "was rejected"
      assert render(view) =~ "re-paste"
    end

    test "an unrecognized refusal renders the honest generic, never a crash", %{
      conn: conn,
      user: user,
      app: app,
      version: version,
      pocket_id_version: pocket_id_version
    } do
      pocketid = ready_pocketid!(user, pocket_id_version)
      expect(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 404}} end)

      url = pocketid_url(pocketid)

      stub(ApiClient, :get_discovery, fn ^url -> {:ok, @issuer} end)
      # A refused mint's raw status map — no atom, no known shape.
      stub(ApiClient, :create_client, fn ^url, _key, _attrs ->
        {:error, %{status: 400, body: "nope"}}
      end)

      {:ok, view, _html} = open_wizard(conn, app)
      to_ticked_step_2(view, version)
      to_step_4(view)
      submit(view)

      assert has_element?(view, "#pocketid-wiring-choice")
      assert render(view) =~ "couldn&#39;t be wired"
      assert render(view) =~ "400"
    end

    test "crafted choice events with nothing standing are silence", %{
      conn: conn,
      app: app,
      version: version
    } do
      {:ok, view, _html} = open_wizard(conn, app)

      render_click(view, "deploy-without-sso", %{})
      render_click(view, "retry-pocketid", %{})
      render_click(view, "open-instance", %{})

      # Still on the wizard, nothing created, nothing crashed.
      assert has_element?(view, "#version-#{version.id}")
    end
  end

  describe "the ride-along strip (belt and braces under the force_change)" do
    test "a crafted recipe-key value re-added after the tick never reaches the create", %{
      conn: conn,
      user: user,
      app: app,
      version: version,
      pocket_id_version: pocket_id_version
    } do
      pocketid = ready_pocketid!(user, pocket_id_version)
      expect(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 404}} end)
      green_wiring!(pocketid)

      {:ok, view, _html} = open_wizard(conn, app)
      to_ticked_step_2(view, version)

      # The DOM cannot produce this (the inputs are hidden and the
      # tick dropped the values) — a hostile env-continue re-adds a
      # recipe value behind a ticked offer anyway.
      view
      |> element("#env-form")
      |> render_submit(%{
        env_values: %{"SMTP_HOST" => "smtp.example", "SSO_AUTHORITY" => "https://hostile.example"}
      })

      view
      |> form("#resources-form")
      |> render_submit()

      submit(view, "Ride Along")

      assert_redirect(view)

      # The strip dropped it at submit; the wiring's force_change owns
      # the key either way. The user's unrelated value ships.
      env = created!(user, version).env_vars
      assert env["SMTP_HOST"] == "smtp.example"
      assert env["SSO_AUTHORITY"] == @issuer
    end
  end
end
