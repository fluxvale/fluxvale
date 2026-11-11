defmodule FluxValeWeb.AdminHealthLiveTest do
  @moduledoc false

  # The Health section (#702): the fleet at a glance through the real
  # mount. The route gates here are the shared live_session's arms
  # (the anonymous 302 and the non-admin 403, pinned once — the
  # people/audit tests' shape). Sync module: tests manipulate the app
  # env (the capture-and-restore posture; ExUnit runs sync modules
  # alone).

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Observability.WakeStats
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers
  alias FluxValeWeb.AdminHealth

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    InstanceFixtures.local_cluster!()

    admin =
      User.create!("admin-health-live-#{@n}@fluxvale.com", %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin), bare_conn: conn}
  end

  # A fleet fixture through actions (the fixture user's funded
  # personal org owns it; the admin reads it through the blanket
  # bypass), always-on toggled on so the summary numbers carry a
  # delta, plus fabricated version rows — Ash.Seed is the sanctioned
  # bypass: the real :deploy action enqueues k8s/Oban work a test must
  # not run. The trail gets a deploy row with an actor and one with
  # the nil tombstone (both render arms); a :create row rides its own
  # source id, dated NEWEST — if the trail's filter ever broke, the
  # creator's row would lead it. The before-read is the delta baseline
  # for the summary-number assertions (the seam itself, same admin
  # actor the mount will use).
  defp fleet_fixtures!(admin) do
    version = InstanceFixtures.app_version!(configurable_env_vars: %{})
    member = AccountsFixtures.user!()

    before = AdminHealth.fleet(admin)

    instance = InstanceFixtures.instance!(version, member)
    Instance.set_always_on!(instance, %{always_on: true}, actor: member)

    source = Ecto.UUID.generate()
    create_source = Ecto.UUID.generate()
    now = DateTime.utc_now()

    Ash.Seed.seed!(FluxVale.Infrastructure.Instance.Version, %{
      version_action_type: :update,
      version_action_name: :deploy,
      version_action_inputs: %{},
      version_source_id: source,
      actor_label: "deployer",
      version_inserted_at: now,
      changes: %{}
    })

    Ash.Seed.seed!(FluxVale.Infrastructure.Instance.Version, %{
      version_action_type: :update,
      version_action_name: :deploy,
      version_action_inputs: %{},
      version_source_id: source,
      actor_label: nil,
      version_inserted_at: DateTime.add(now, -60, :second),
      changes: %{}
    })

    Ash.Seed.seed!(FluxVale.Infrastructure.Instance.Version, %{
      version_action_type: :create,
      version_action_name: :create,
      version_action_inputs: %{},
      version_source_id: create_source,
      actor_label: "creator",
      version_inserted_at: DateTime.add(now, 600, :second),
      changes: %{}
    })

    %{source: source, create_source: create_source, before: before}
  end

  defp text_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  # The wake maps come from WakeStats — the app tree's named server
  # fed by PromEx, which this suite never starts. The stub rides the
  # wake_stats test's own tooling: raise the TTL so an injected cache
  # is served, then inject both maps through :sys.replace_state (OTP
  # tooling, not an app backdoor). On exit BOTH pieces of app-owned
  # state go back — the TTL (capture-and-restore) and the cache itself
  # — so no fabricated map can outlive the test even for a later
  # TTL-raising reader.
  defp wake_stub!(p95_promotion, median_total) do
    original_ttl = Application.get_env(:flux_vale, :wake_stats_ttl_seconds)
    Application.put_env(:flux_vale, :wake_stats_ttl_seconds, 3600)

    on_exit(fn ->
      if original_ttl == nil do
        Application.delete_env(:flux_vale, :wake_stats_ttl_seconds)
      else
        Application.put_env(:flux_vale, :wake_stats_ttl_seconds, original_ttl)
      end
    end)

    previous_state = :sys.get_state(WakeStats)

    on_exit(fn ->
      :sys.replace_state(WakeStats, fn _state -> previous_state end)
    end)

    computed_at = DateTime.utc_now()

    :sys.replace_state(WakeStats, fn _state ->
      %{computed_at: computed_at, medians: median_total, p95_promotions: p95_promotion}
    end)
  end

  describe "the fleet surface" do
    test "an admin sees the section, the spread, and the deploy trail", %{
      conn: conn,
      admin: admin
    } do
      %{source: source, create_source: create_source, before: before} = fleet_fixtures!(admin)

      {:ok, view, _html} = live(conn, "/admin/health")

      assert has_element?(view, "[data-testid='admin-health']")
      assert has_element?(view, "[data-testid='admin-health-title']", "Health")

      # The build stamp: the version chip always renders (its value is
      # pinned against a stubbed sha in the dedicated test below); the
      # env chip rides config's "local" default.
      assert has_element?(view, "[data-testid='fleet-version']")
      assert has_element?(view, "[data-testid='fleet-env']")

      # The summary numbers, exact for the fixture state: the deltas
      # this test created (+1 instance, +1 always-on) over the
      # before-read — the partition's committed strays are IN the
      # before-read, so the absolute number is this test's own.
      assert text_of(view, "[data-testid='fleet-total']") ==
               ngettext_exact(before.total + 1, "1 instance", "%{count} instances")

      assert text_of(view, "[data-testid='fleet-always-on']") ==
               ngettext_exact(before.always_on + 1, "1 always-on", "%{count} always-on")

      # The spread renders the product's own vocabulary (#179) through
      # the shared status_badge: the created instance lands :pending —
      # "Submitted".
      assert has_element?(view, "[data-testid='fleet-status-pending']", "Submitted")

      # The trail rows: the engine's short id, the recorded actor
      # label, and the nil tombstone's honest System attribution. The
      # creator's row (the table's newest, on its own source) renders
      # nowhere — the deploy-only filter holds through the mount.
      deploys_text = text_of(view, "[data-testid='fleet-deploys']")
      assert deploys_text =~ String.slice(source, 0, 8)
      assert deploys_text =~ "deployer"
      assert deploys_text =~ "System"
      refute deploys_text =~ "creator"
      refute deploys_text =~ String.slice(create_source, 0, 8)

      # The empty line stays quiet while the trail has rows.
      refute has_element?(view, "[data-testid='fleet-deploys-empty']")

      # The section's sidebar entry is the page; siblings stay quiet.
      assert has_element?(view, "[data-testid='admin-nav-health'][aria-current='page']")
      refute render(element(view, "[data-testid='admin-nav-audit']")) =~ "aria-current"
    end

    test "the version chip renders the pinned build sha", %{conn: conn} do
      # The stub_build_sha posture (the health controller tests'
      # shape): assertions own their preconditions — ambient BUILD_SHA
      # from the environment included — so the chip's rendered value
      # is this test's own, not the runner's mood.
      previous = Application.get_env(:flux_vale, :build_sha)
      Application.put_env(:flux_vale, :build_sha, "c1fixsha")

      on_exit(fn ->
        if previous == nil do
          Application.delete_env(:flux_vale, :build_sha)
        else
          Application.put_env(:flux_vale, :build_sha, previous)
        end
      end)

      {:ok, view, _html} = live(conn, "/admin/health")

      assert has_element?(view, "[data-testid='fleet-version']", "Version: sha-c1fixsha")
    end

    test "the env chip renders nothing when the platform has no env", %{conn: conn} do
      # Capture-and-restore (the stub_build_sha posture): config.exs
      # defaults "local", so the nil shape arrives only when unset.
      original = Application.get_env(:flux_vale, :platform_env)
      Application.put_env(:flux_vale, :platform_env, nil)

      on_exit(fn ->
        if original == nil do
          Application.delete_env(:flux_vale, :platform_env)
        else
          Application.put_env(:flux_vale, :platform_env, original)
        end
      end)

      {:ok, view, _html} = live(conn, "/admin/health")

      refute has_element?(view, "[data-testid='fleet-env']")
      assert has_element?(view, "[data-testid='fleet-version']")

      # The emptiness claim is scoped to what this test controls: a
      # source id it fabricated and never seeded can never name a
      # trail row. The partition's committed rows are not this test's
      # to assert absent — a has-element claim on the empty line would
      # own a global state that is not ours.
      fabricated = Ecto.UUID.generate()

      refute text_of(view, "[data-testid='fleet-deploys']") =~ String.slice(fabricated, 0, 8)
    end
  end

  # The ngettext branches, spelled out — a fresh partition with zero
  # strays renders the singular, and the always-on plural never takes
  # an s.
  defp ngettext_exact(1, singular, _plural), do: singular

  defp ngettext_exact(count, _singular, plural),
    do: String.replace(plural, "%{count}", Integer.to_string(count))

  describe "the wake surface" do
    test "the wake rows render per app with both families' seconds", %{conn: conn} do
      # kavita rides both families; forgejo is in the promotion family
      # only, so its median renders the honest dash. The injected cache
      # is the row set's only source — an app in neither family can
      # never render, so the absence below is this test's own.
      wake_stub!(%{"kavita" => 2.95, "forgejo" => 4.1}, %{"kavita" => 6.5})

      {:ok, view, _html} = live(conn, "/admin/health")

      assert has_element?(view, "[data-testid='wake-panel']")
      assert has_element?(view, "[data-testid='wake-title']", "Wakes")

      # The numbers, exact for the stubbed estimates.
      kavita = text_of(view, "[data-testid='wake-kavita']")
      assert kavita =~ "p95 promotion 2.95s"
      assert kavita =~ "median total 6.5s"

      forgejo = text_of(view, "[data-testid='wake-forgejo']")
      assert forgejo =~ "p95 promotion 4.1s"
      assert forgejo =~ "median total -"

      # The caveat line: the widget's honesty note rides every render.
      assert text_of(view, "[data-testid='wake-caveat']") =~ "reset on every deploy"

      refute has_element?(view, "[data-testid='wake-promnesia']")
    end
  end

  describe "the gates" do
    test "anonymous bounces to /sign-in", %{bare_conn: conn} do
      conn = get(conn, "/admin/health")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "a signed-in non-admin gets a bare 403", %{bare_conn: conn} do
      user = SessionHelpers.user!()
      signed = SessionHelpers.sign_in(conn, user)
      conn = get(signed, "/admin/health")

      assert conn.status == 403
    end
  end
end
