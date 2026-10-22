defmodule FluxValeWeb.CatalogLive.DeployTest do
  @moduledoc false

  # The deploy stepper (#74): version → env (schema-rendered) → name →
  # create + auto-deploy. K8s is stubbed (Mimic, v1's canonical pattern)
  # because Oban runs inline in tests — the deploy trigger executes
  # synchronously on submit.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import FluxVale.TestSupport.NoK8sLeaks
  import Phoenix.LiveViewTest

  alias FluxVale.Clients.K8s

  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service

  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Pricing.Size
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @schema %{
    "SMTP_HOST" => %{
      label: "SMTP host",
      description: "Hostname of the SMTP server.",
      type: :string
    },
    "SMTP_PORT" => %{label: "SMTP port", type: :integer, default: 587},
    "DISABLE_SIGNUP" => %{label: "Disable sign-up", type: :boolean, default: false},
    "SMTP_PASSWD" => %{label: "SMTP password", type: :string, secret: true}
  }

  setup %{conn: conn} do
    {user, conn} = SessionHelpers.user_with_session(conn)
    cluster = InstanceFixtures.local_cluster!()

    version =
      InstanceFixtures.app_version!(
        configurable_env_vars: @schema,
        default_storage_gb: 10,
        published_at: DateTime.utc_now()
      )

    app = Ash.load!(version, :app, authorize?: false).app
    {:ok, user: user, conn: conn, app: app, version: version, cluster: cluster}
  end

  defp stub_k8s do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Secret, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
  end

  defp to_step_2(view, version) do
    view
    |> element("#version-#{version.id}")
    |> render_click()

    view
    |> element("button[phx-click='to-env']")
    |> render_click()
  end

  defp to_step_3(view, env \\ %{}) do
    view
    |> element("#env-form")
    |> render_submit(%{env_values: env})
  end

  # The resources step's Continue — `resources` overrides the inputs
  # (string values, as the number inputs carry them); defaults flow
  # when omitted.
  defp to_step_4(view, resources \\ %{}) do
    view
    |> form("#resources-form", resources: resources)
    |> render_submit()
  end

  test "renders the version step", %{conn: conn, app: app, version: version} do
    {:ok, view, html} = live(conn, ~p"/apps/#{app.slug}/deploy")

    assert has_element?(view, "#version-#{version.id}")
    assert has_element?(view, "button[phx-click='to-env']")

    assert has_element?(
             view,
             "[data-testid='version-price-#{version.version}']",
             "$1.00/mo · billed hourly"
           )

    assert html =~ "published"
  end

  # #179's surface audit: the stepper renders across all three steps
  # and flashes after events — none of it may name the platform under
  # the hood.
  test "every stepper step and flash renders k8s-free", %{conn: conn, app: app, version: version} do
    {:ok, view, html} = live(conn, ~p"/apps/#{app.slug}/deploy")

    # The step-guard flash (a crafted event with no pick) too.
    flashed = render_click(view, "to-env", %{})
    assert flashed =~ "Pick a version first."
    refute_k8s_terms(flashed)

    to_step_2(view, version)
    refute_k8s_terms(render(view))

    to_step_3(view, %{"SMTP_HOST" => "smtp.example.com"})
    refute_k8s_terms(render(view))
  end

  test "unknown slug redirects to the catalog", %{conn: conn} do
    case live(conn, ~p"/apps/nope/deploy") do
      {:ok, view, _html} ->
        assert_redirect(view, ~p"/apps")

      {:error, {:live_redirect, %{to: to}}} ->
        assert to == ~p"/apps"
    end
  end

  test "a channel-level to-env without a pick stays on the version step", %{
    conn: conn,
    app: app
  } do
    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")

    # The Continue button is disabled client-side only — the server-side
    # guard must hold for a crafted event
    html = render_click(view, "to-env", %{})

    assert html =~ "Pick a version first."
    assert has_element?(view, "button[phx-click='to-env']")
  end

  test "channel-level resource events before a pick neither crash nor advance", %{
    conn: conn,
    app: app
  } do
    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")

    # Crafted before any version is selected: nil selected version must
    # not crash the handler (to-env's guard posture).
    _html = render_click(view, "resources-change", %{"resources" => %{"memory_mb" => "128"}})

    assert has_element?(view, "button[phx-click='to-env']")

    html = render_click(view, "resources-continue", %{"resources" => %{}})

    assert html =~ "Pick a version first."
  end

  test "a channel-level env-continue before a pick stays on the version step", %{
    conn: conn,
    app: app
  } do
    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")

    # The env gate would crash deriving the resources defaults from a
    # nil version — it holds the to-env posture instead.
    html = render_click(view, "env-continue", %{"env_values" => %{}})

    assert html =~ "Pick a version first."
    assert has_element?(view, "button[phx-click='to-env']")
  end

  # No configurable env vars on the version: the env step renders its
  # nothing-to-configure shape and its own Continue advances (#178
  # wave 2 — the branch rides <.button> component calls now, which
  # surfaced as coverable lines).
  test "an env-less version renders the nothing-to-configure step and continues", %{
    conn: conn
  } do
    version = InstanceFixtures.app_version!(configurable_env_vars: %{})
    app = Ash.load!(version, :app, authorize?: false).app

    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
    to_step_2(view, version)

    assert render(view) =~ "Nothing to configure for this app"
    refute has_element?(view, "#env-form")

    view
    |> element("[data-testid='continue-env']")
    |> render_click()

    assert has_element?(view, "#resources-form")
  end

  test "the env step renders schema-typed inputs and walks back", %{
    conn: conn,
    app: app,
    version: version
  } do
    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
    to_step_2(view, version)

    assert has_element?(view, "#env-SMTP_HOST")
    assert has_element?(view, "#env-SMTP_PORT[type='number']")
    assert has_element?(view, "#env-SMTP_PASSWD[type='password']")
    assert has_element?(view, "#env-DISABLE_SIGNUP option[value='true']")
    assert render(view) =~ "Hostname of the SMTP server."

    view
    |> element("button[phx-click='back-version']")
    |> render_click()

    assert has_element?(view, "#version-#{version.id}")

    to_step_2(view, version)
    to_step_3(view)
    to_step_4(view)

    # The name step carries ADR-0028's estimate for the picked version.
    assert has_element?(view, "[data-testid='price-summary']", "$1.00/mo · billed hourly")

    # From the name step, back returns to resources, and again to env
    view
    |> element("button[phx-click='back-resources']")
    |> render_click()

    assert has_element?(view, "#resources-form")

    view
    |> element("button[phx-click='back-env']")
    |> render_click()

    assert has_element?(view, "#env-form")

    to_step_3(view)
    to_step_4(view)

    assert has_element?(view, "#deploy-form")
  end

  test "a bad integer env value bounces back to the env step with the error", %{
    conn: conn,
    app: app,
    version: version
  } do
    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
    to_step_2(view, version)

    html = to_step_3(view, %{"SMTP_PORT" => "not-a-number"})

    assert html =~ "SMTP_PORT"
    assert html =~ "whole number"
    assert has_element?(view, "#env-form")
  end

  test "the full flow creates the instance and auto-deploys", %{
    conn: conn,
    user: user,
    app: app,
    version: version
  } do
    stub_k8s()
    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")

    to_step_2(view, version)

    to_step_3(view, %{"SMTP_HOST" => "smtp.example.com", "SMTP_PORT" => "2525"})

    to_step_4(view)

    view
    |> form("#deploy-form", instance: %{name: "My Forgejo"})
    |> render_submit()

    assert_redirect(view)

    [instance] = Instance.list_for_actor!(actor: user)

    # Inline Oban ran the deploy trigger through the stubs: the
    # namespace is pinned and the state machine has moved.
    assert instance.name == "My Forgejo"
    assert instance.status == :starting
    assert instance.namespace == "fluxvale-app-#{instance.id}"
    assert instance.env_vars["SMTP_HOST"] == "smtp.example.com"
    # user value over the schema default
    assert instance.env_vars["SMTP_PORT"] == "2525"
    # untouched schema default still ships
    assert instance.env_vars["DISABLE_SIGNUP"] == "false"
    assert instance.app_version_id == version.id
    # untouched resource controls default to the recommendation (#180)
    assert instance.cpu_cores == Decimal.new("0.5")
    assert instance.memory_mb == 256
    assert instance.storage_gb == 10
  end

  test "a missing name stays on the name step with the field error", %{
    conn: conn,
    app: app,
    version: version
  } do
    stub_k8s()
    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
    to_step_2(view, version)
    to_step_3(view)
    to_step_4(view)

    html =
      view
      |> form("#deploy-form", instance: %{name: ""})
      |> render_submit()

    assert html =~ "Fix the errors above"
    assert has_element?(view, "#deploy-form")
  end

  test "an error that only surfaces at submit drops back to its step (version deleted mid-stepper)",
       %{
         conn: conn,
         app: app,
         version: version
       } do
    stub_k8s()
    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
    to_step_2(view, version)
    to_step_3(view, %{})
    to_step_4(view)

    # The version dies between the env gate and submit — the save's
    # re-validation fails on app_version_id, invisible on the name step.
    Ash.destroy!(version, authorize?: false)

    html =
      view
      |> form("#deploy-form", instance: %{name: "Orphan"})
      |> render_submit()

    assert html =~ "Fix the errors above"
    assert has_element?(view, "#env-form")
  end

  test "a channel-level save from before the resources step falls back to the recommendation",
       %{conn: conn, user: user, app: app, version: version} do
    stub_k8s()
    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")

    to_step_2(view, version)

    # The resources step never ran — no allocation in LiveView state.
    # The crafted save must neither crash nor smuggle an allocation:
    # the instance lands at the version's defaults (the recommendation).
    render_click(view, "save", %{"instance" => %{"name" => "Ghost"}})

    assert_redirect(view)

    [instance] = Instance.list_for_actor!(actor: user)

    # An explicit nil allocation rides the same path: the nil-able
    # attrs accept it at cast, the derive normalizes it to the default
    # (nil into the allocation comparison or the curve would crash).
    {:ok, view2, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")

    to_step_2(view2, version)

    render_click(view2, "save", %{"instance" => %{"name" => "Nil Ghost", "cpu_cores" => nil}})

    assert_redirect(view2)

    instances = Instance.list_for_actor!(actor: user, authorize?: false)
    nil_instance = Enum.find(instances, &(&1.name == "Nil Ghost"))

    assert nil_instance.cpu_cores == Decimal.new("0.5")
    assert nil_instance.memory_mb == 256
    assert nil_instance.storage_gb == 10
    assert nil_instance.size_id

    assert instance.name == "Ghost"
    assert instance.cpu_cores == Decimal.new("0.5")
    assert instance.memory_mb == 256
    assert instance.storage_gb == 10
  end

  test "a channel-level back-resources before the env gate renders the resources step safely",
       %{conn: conn, app: app, version: version} do
    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")

    to_step_2(view, version)

    # Crafted nav with no allocation state yet (@resources nil): the
    # step renders empty controls priced at the recommendation rather
    # than crashing on the nil.
    render_click(view, "back-resources", %{})

    assert has_element?(view, "#resources-form")
    assert has_element?(view, "[data-testid='resources-price']", "$1.00/mo · billed hourly")
  end

  test "a channel-level back-resources before a pick stays on the version step", %{
    conn: conn,
    app: app
  } do
    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")

    render_click(view, "back-resources", %{})

    assert has_element?(view, "button[phx-click='to-env']")
  end

  test "a crafted partial resources-change before the env gate merges over the recommendation",
       %{conn: conn, app: app, version: version} do
    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")

    to_step_2(view, version)

    # @resources is nil here: the sent key lands on the recommendation
    # base, so the untouched dimensions keep the version's defaults.
    # (State updates even off-step; the crafted nav makes it visible.)
    render_click(view, "resources-change", %{"resources" => %{"memory_mb" => "128"}})

    render_click(view, "back-resources", %{})

    assert has_element?(view, "#resource-cpu-cores[value='0.5']")
    assert has_element?(view, "#resource-memory-mb[value='128']")
    assert has_element?(view, "#below-recommendation-warning")
  end

  describe "the resource picker (#195 — selectable, never typed)" do
    setup %{conn: conn, app: app, version: version} do
      # The quick picks are the seeded sizes (shipped business data);
      # the shared test DB carries none until a seed test runs, so seed
      # them for this suite's transaction.
      :ok = FluxVale.Seeds.seed_pricing!()

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)
      to_step_3(view)

      %{view: view, version: version}
    end

    test "no free-text control renders on the resources step", %{view: view} do
      # The whole point of #195: the allocation is picked, never typed.
      refute has_element?(view, "#resources-form input[type='text']")
      refute has_element?(view, "#resources-form input[type='number']")
      refute has_element?(view, "#resources-form textarea")

      # …and the selectable controls are there instead.
      assert has_element?(
               view,
               "#resources-form input[type='range'][name='resources[cpu_cores]']"
             )

      assert has_element?(
               view,
               "#resources-form input[type='range'][name='resources[memory_mb]']"
             )

      assert has_element?(
               view,
               "#resources-form input[type='range'][name='resources[storage_gb]']"
             )
    end

    test "every slider is bounded by the platform range and snapped", %{view: view} do
      # The bounds are the platform's own ceilings; the step is the
      # fixed granularity the arrow keys snap to.
      assert has_element?(view, "#resource-cpu-cores[min='0.25'][max='64'][step='0.25']")
      assert has_element?(view, "#resource-memory-mb[min='128'][max='65536'][step='128']")
      assert has_element?(view, "#resource-storage-gb[min='0'][max='10240'][step='5']")
    end

    test "the sliders carry accessible labels and a unit-announcing readout", %{view: view} do
      html = render(view)

      assert html =~ ~s(for="resource-cpu-cores")
      assert html =~ ~s(aria-valuetext="0.5 cores")
      assert html =~ ~s(aria-valuetext="256 MB")
      assert html =~ ~s(aria-valuetext="10 GB")
    end

    test "every seeded size sits exactly on the three sliders' ladders", %{view: view} do
      # The picker's contract (the comment on resource_dimensions/0):
      # the granularities divide every seeded size, so a preset's value
      # is always a ladder value — the thumb can never round beneath the
      # state and fork the shown price from the charge. A seed/price
      # edit that breaks this hides that size from the quick picks
      # (representable_size?/1), and that is what the second half pins.
      sizes = Ash.read!(Size, authorize?: false)
      assert sizes != []

      for size <- sizes do
        cpu = Decimal.to_string(size.cpu_cores)
        on_cpu_ladder = Decimal.rem(size.cpu_cores, Decimal.new("0.25"))
        assert Decimal.eq?(on_cpu_ladder, Decimal.new(0)), cpu
        assert Decimal.compare(size.cpu_cores, Decimal.new("0.25")) != :lt
        assert Decimal.compare(size.cpu_cores, Decimal.new("64")) != :gt
        assert rem(size.memory_mb, 128) == 0 and size.memory_mb in 128..65_536, cpu
        assert rem(size.storage_gb, 5) == 0 and size.storage_gb in 0..10_240, cpu
        assert has_element?(view, "[data-testid='preset-#{size.slug}']")
      end
    end

    test "an off-ladder version default snaps to the ladder, keeping price and value one number",
         %{conn: conn} do
      # ADR-0027 can put an allocation the ladders can't express on a
      # version's defaults (the admin path); a range input would round it
      # in the browser the moment it renders, so the server snaps first
      # — the shown readout, the submitted value and the price line all
      # describe one allocation. 300 MB snaps down to 256 (the fixture's
      # memory default) and 0.1 CPU snaps up to the 0.25 floor.
      version =
        InstanceFixtures.app_version!(
          default_cpu_cores: Decimal.new("0.1"),
          default_memory_mb: 300,
          default_storage_gb: 7,
          published_at: DateTime.utc_now()
        )

      app = Ash.load!(version, :app, authorize?: false).app

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)

      # This fixture carries no env schema — the env step's
      # nothing-to-configure Continue (the #178 wave 2 branch).
      view
      |> element("[data-testid='continue-env']")
      |> render_click()

      assert has_element?(view, "#resource-cpu-cores[value='0.25']")
      assert has_element?(view, "#resource-memory-mb[value='256']")
      assert has_element?(view, "#resource-storage-gb[value='5']")

      # The readout announces the snapped value, not the admin's raw one.
      # (The "recommends …" copy above still names the app's true
      # default — that is a statement about the app, not about what the
      # picker can offer; the controls and their readouts are what must
      # never disagree with the submitted value.)
      html = render(view)
      assert html =~ ~s(aria-valuetext="0.25 cores")
      assert html =~ ~s(aria-valuetext="256 MB")
      refute html =~ ~s(aria-valuetext="300 MB")
      refute has_element?(view, "#resource-memory-mb[value='300']")

      # The copy no longer claims the controls match the recommendation:
      # 256 MB IS below the app's 300 MB, so the heads-up is honest and
      # mounts on the first render without any user action.
      refute html =~ "the defaults below"
      assert has_element?(view, "#below-recommendation-warning")

      # An unrelated event re-renders from state without forking the
      # number the inputs carry.
      render_change(view, "resources-change", %{"resources" => %{"memory_mb" => "256"}})

      assert has_element?(view, "#resource-cpu-cores[value='0.25']")
      assert has_element?(view, "#resource-memory-mb[value='256']")
    end

    test "an integer-valued ladder default renders expanded, never in scientific notation",
         %{conn: conn} do
      # Decimal.normalize/1 lowers the exponent, so an integer whose
      # coefficient ends in a zero inspects as 1E+1 — a value no range
      # input can carry. A 10-core default must render "10".
      version =
        InstanceFixtures.app_version!(
          default_cpu_cores: Decimal.new("10"),
          default_memory_mb: 2048,
          default_storage_gb: 20,
          published_at: DateTime.utc_now()
        )

      app = Ash.load!(version, :app, authorize?: false).app

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)

      view
      |> element("[data-testid='continue-env']")
      |> render_click()

      assert has_element?(view, "#resource-cpu-cores[value='10']")
      refute render(view) =~ "1E+1"
    end

    test "an admin allocation the ladders can't express is not offered as a quick pick",
         %{conn: conn, app: app, version: version} do
      # ADR-0027 lets an admin add any Size the schema accepts; a preset
      # that its own wizard would refuse or silently clamp is worse than
      # none, so representable_size?/1 filters it out of the picks.
      off_ladder =
        Size.create!(
          %{
            slug: "off-ladder-#{System.unique_integer([:positive])}",
            cpu_cores: Decimal.new("0.3"),
            memory_mb: 300,
            storage_gb: 7,
            monthly_cents: 123,
            stopped_monthly_cents: 12
          },
          authorize?: false
        )

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)
      to_step_3(view)

      # Its neighbours (the seeded sizes) are still offered — the filter
      # is per size, not a blanket bail-out.
      assert has_element?(view, "[data-testid='preset-small']")
      refute has_element?(view, "[data-testid='preset-#{off_ladder.slug}']")

      # And a crafted pick of it still can't smuggle in an unclamped
      # allocation (the handler looks it up in the filtered list).
      render_click(view, "pick-size", %{"slug" => off_ladder.slug})

      assert has_element?(view, "#resource-memory-mb[value='256']")
    end

    test "the seeded sizes render as quick picks, the recommendation called out",
         %{view: view, version: version} do
      for slug <- ~w(micro small medium standard plus pro) do
        assert has_element?(view, "[data-testid='preset-#{slug}']")
      end

      # The version's own recommended size is called out (the fixture's
      # fabricated size — loaded here, it rides the fixture unloaded).
      recommended =
        Ash.load!(version, :recommended_size, authorize?: false).recommended_size.slug

      assert has_element?(view, "#preset-#{recommended}", "recommended")

      # The fixture fabricates its size to match the version's defaults,
      # so the recommendation is also the pressed quick pick — a
      # meaningful `aria-pressed="true"`, not just the attribute's
      # presence.
      assert has_element?(view, "#preset-#{recommended}[aria-pressed='true']")
    end

    test "picking a size sets the whole allocation and reprices from the curve", %{view: view} do
      # `standard` is 1 CPU / 2048 MB / 20 GB — a custom allocation for
      # this fixture's version (0.5/256/10).
      view
      |> element("[data-testid='preset-standard']")
      |> render_click()

      assert has_element?(view, "#resource-cpu-cores[value='1']")
      assert has_element?(view, "#resource-memory-mb[value='2048']")
      assert has_element?(view, "#resource-storage-gb[value='20']")

      # The price follows the allocation (#186): the anchor formula at
      # 1 CPU / 2048 MB / 20 GB — which the seeded table pins at the
      # standard size's $6.21 (B′) — never this fixture's $1.00 size price.
      assert has_element?(view, "[data-testid='resources-price']", "$6.21/mo · billed hourly")
      refute has_element?(view, "[data-testid='resources-price']", "$1.00/mo · billed hourly")

      assert has_element?(view, "[data-testid='preset-standard'][aria-pressed='true']")
    end

    test "a preset above the recommendation never warns", %{view: view} do
      view
      |> element("[data-testid='preset-pro']")
      |> render_click()

      refute has_element?(view, "#below-recommendation-warning")
      assert has_element?(view, "[data-testid='resources-price']")
    end

    test "a size below the recommendation trips the heads-up + ack flow", %{view: view} do
      # `micro` (0.25/512/5) is below this fixture's 0.5/256/10 on CPU
      # only — enough for the gate.
      view
      |> element("[data-testid='preset-micro']")
      |> render_click()

      assert has_element?(view, "#below-recommendation-warning")
      assert has_element?(view, "#below-recommendation-ack")
    end

    test "a crafted unknown preset slug changes nothing", %{view: view} do
      render_click(view, "pick-size", %{"slug" => "does-not-exist"})

      # The rendered buttons can't produce one; a hostile client gets
      # silence, not a crash and not a bogus allocation.
      assert has_element?(view, "#resource-cpu-cores[value='0.5']")
      assert has_element?(view, "#resource-memory-mb[value='256']")
      assert has_element?(view, "#resources-form")
    end

    test "a crafted preset pick before a version is picked neither crashes nor advances",
         %{conn: conn, app: app} do
      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")

      render_click(view, "pick-size", %{"slug" => "standard"})

      # Still on the version step (to-env's guard posture).
      assert has_element?(view, "button[phx-click='to-env']")
      refute has_element?(view, "#resources-form")
    end
  end

  describe "the resources step (#180)" do
    setup %{conn: conn, app: app, version: version} do
      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)
      to_step_3(view)

      %{view: view}
    end

    test "defaults to the recommendation and prices at it", %{view: view} do
      # The version's defaults (0.5 CPU / 256 MB / 10 GB) prefill the
      # controls and label the recommendation.
      assert has_element?(view, "#resource-cpu-cores[value='0.5']")
      assert has_element?(view, "#resource-memory-mb[value='256']")
      assert has_element?(view, "#resource-storage-gb[value='10']")
      assert has_element?(view, "[data-testid='recommended-allocation']")

      # At the recommendation: no warning, no ack, the size price
      # (the fixture's fabricated size — the seeded size/formula
      # equivalence is the calibration tests' contract, not this
      # fixture's).
      refute has_element?(view, "#below-recommendation-warning")
      assert has_element?(view, "[data-testid='resources-price']", "$1.00/mo · billed hourly")

      # The estimate tracks the inputs live (#186's done-when): a bump
      # reprices, and back at the recommendation the size price returns.
      view
      |> form("#resources-form", resources: %{cpu_cores: "1"})
      |> render_change()

      assert has_element?(view, "[data-testid='resources-price']", "$3.48/mo · billed hourly")

      view
      |> form("#resources-form", resources: %{cpu_cores: "0.5"})
      |> render_change()

      assert has_element?(view, "[data-testid='resources-price']", "$1.00/mo · billed hourly")

      to_step_4(view)

      assert has_element?(view, "[data-testid='price-summary']", "$1.00/mo · billed hourly")
    end

    test "an above-recommendation allocation deploys unrestricted at the formula price",
         %{user: user, view: view} do
      stub_k8s()

      view
      |> form("#resources-form",
        resources: %{cpu_cores: "1", memory_mb: "512", storage_gb: "20"}
      )
      |> render_change()

      refute has_element?(view, "#below-recommendation-warning")

      # The live estimate follows the allocation (#186): the anchor
      # formula at 1 CPU / 512 MB / 20 GB, on the resources step and
      # carried to the name step. No interim copy remains.
      assert has_element?(view, "[data-testid='resources-price']", "$4.18/mo · billed hourly")

      to_step_4(view)

      assert has_element?(view, "[data-testid='price-summary']", "$4.18/mo · billed hourly")
      refute render(view) =~ "billed at the recommended size"

      view
      |> form("#deploy-form", instance: %{name: "Bigger"})
      |> render_submit()

      assert_redirect(view)

      [instance] = Instance.list_for_actor!(actor: user)

      assert instance.cpu_cores == Decimal.new("1")
      assert instance.memory_mb == 512
      assert instance.storage_gb == 20

      # The ledger charges exactly what the wizard showed: the formula
      # cents snapshot at create (no size for a custom allocation).
      assert instance.size_id == nil
      assert instance.grandfathered_monthly_cents == 418
      assert instance.grandfathered_stopped_monthly_cents == 68
      assert instance.grandfathered_until
    end

    test "a below-recommendation allocation warns and gates on an explicit acknowledgment",
         %{user: user, view: view} do
      stub_k8s()

      view
      |> form("#resources-form", resources: %{memory_mb: "128"})
      |> render_change()

      assert has_element?(view, "#below-recommendation-warning")
      assert render(view) =~ "it may run slowly or fail"

      # A channel-level continue without the ack stays put (the disabled
      # button is client-side only).
      html = render_click(view, "resources-continue", %{"resources" => %{"memory_mb" => "128"}})

      assert html =~ "Acknowledge the below-recommendation warning"
      assert has_element?(view, "#resources-form")

      # The estimate follows the below-recommendation allocation too —
      # the ack flow prices, it doesn't hide.
      assert has_element?(view, "[data-testid='resources-price']", "$2.68/mo · billed hourly")

      # The ack rides the form; Continue proceeds and the deploy lands
      # at the chosen (lower) allocation.
      to_step_4(view, %{memory_mb: "128", below_ack: "on"})

      view
      |> form("#deploy-form", instance: %{name: "Smaller"})
      |> render_submit()

      assert_redirect(view)

      [instance] = Instance.list_for_actor!(actor: user)

      assert instance.memory_mb == 128
      assert instance.cpu_cores == Decimal.new("0.5")
      assert instance.storage_gb == 10

      # Formula-priced: the below-recommendation snapshot.
      assert instance.size_id == nil
      assert instance.grandfathered_monthly_cents == 268
    end

    test "the hard floors block even with the acknowledgment", %{user: user, view: view} do
      # Below the recommendation first — that mounts the warning and its
      # ack checkbox (the crafted continue below must clear a rendered
      # gate, not one that never existed).
      view
      |> form("#resources-form", resources: %{memory_mb: "128"})
      |> render_change()

      assert has_element?(view, "#below-recommendation-ack")

      # cpu 0 is under the hard floor: blocked even acknowledged.
      html = to_step_4(view, %{cpu_cores: "0", memory_mb: "128", below_ack: "on"})

      assert html =~ "CPU cores must be greater than 0"
      assert has_element?(view, "#resources-form")
      assert Instance.list_for_actor!(actor: user) == []
    end

    test "the ceilings error at continue — a plainly-typed big number must not crash the save",
         %{view: view} do
      html = to_step_4(view, %{memory_mb: "99999999999999999999"})

      assert html =~ "Memory must be at most 65536 MB"
      assert has_element?(view, "#resources-form")

      # Finite-but-huge decimals pass the > 0 floor and would crash the
      # Postgrex numeric write — the cpu ceiling catches them first.
      cpu_html = to_step_4(view, %{cpu_cores: "1e30"})

      assert cpu_html =~ "CPU cores must be at most 64"
      assert has_element?(view, "#resources-form")
    end

    test "non-numeric input errors at continue, not per keystroke", %{view: view} do
      view
      |> form("#resources-form", resources: %{memory_mb: "128"})
      |> render_change()

      # Mid-typing garbage shows no error flash — assessment happens at
      # continue (a number half-typed must not bounce the step).
      change_html =
        view
        |> form("#resources-form", resources: %{cpu_cores: "zero"})
        |> render_change()

      refute change_html =~ "must be a number"

      continue_html = to_step_4(view, %{cpu_cores: "zero"})

      assert continue_html =~ "CPU cores must be a number"
      assert has_element?(view, "#resources-form")
    end

    test "fractional memory errors at continue", %{view: view} do
      html = to_step_4(view, %{memory_mb: "3.5"})

      assert html =~ "Memory and storage must be whole numbers"
      assert has_element?(view, "#resources-form")
    end

    test "non-finite decimals never reach the compares or the floors", %{view: view} do
      # NaN would crash Decimal.compare on every later event; Infinity
      # would walk the floors. Both are cast out up front.
      nan_html = to_step_4(view, %{cpu_cores: "NaN"})

      assert nan_html =~ "CPU cores must be a number"

      infinity_html = to_step_4(view, %{cpu_cores: "Infinity"})

      assert infinity_html =~ "CPU cores must be a number"
      assert has_element?(view, "#resources-form")
    end

    test "curve-crashing values die at the parse, not in the preview", %{view: view} do
      # Negatives and past-DBL_MAX magnitudes would raise inside
      # :math.pow / Decimal.to_float — the preview prices on every
      # keystroke, so the parse owns them (the curve assumes
      # floor-legal input).
      view
      |> form("#resources-form", resources: %{memory_mb: "128"})
      |> render_change()

      change_html =
        view
        |> form("#resources-form", resources: %{cpu_cores: "-1"})
        |> render_change()

      # Live view survived; no price line for an unparseable allocation
      # (the quick picks above still carry their own size prices, so the
      # assertion is scoped to the price line, not the page).
      assert has_element?(view, "#resources-form")
      refute has_element?(view, "[data-testid='resources-price']", "$")
      assert change_html =~ "resources-form"

      negative_html = to_step_4(view, %{cpu_cores: "-1"})

      assert negative_html =~ "CPU cores must be greater than 0"

      overflow_html = to_step_4(view, %{cpu_cores: "1e309"})

      assert overflow_html =~ "CPU cores must be at most 64"

      # A valid cpu so the memory arm's parse actually runs.
      negative_memory_html = to_step_4(view, %{cpu_cores: "0.5", memory_mb: "-5"})

      assert negative_memory_html =~ "Memory and storage cannot be negative"

      # A pasted >308-digit integer would crash the curve's float
      # division on every keystroke — the parse-level ceiling owns it.
      huge = String.duplicate("9", 400)

      view
      |> form("#resources-form", resources: %{memory_mb: huge})
      |> render_change()

      assert has_element?(view, "#resources-form")

      overflow_int_html = to_step_4(view, %{memory_mb: huge})

      assert overflow_int_html =~ "Memory must be at most 65536 MB"
    end

    test "a back-nav round trip keeps the chosen allocation", %{view: view} do
      view
      |> form("#resources-form", resources: %{cpu_cores: "1", memory_mb: "512"})
      |> render_change()

      view
      |> element("button[phx-click='back-env']")
      |> render_click()

      view
      |> element("#env-form")
      |> render_submit(%{env_values: %{}})

      # The env detour preserved the values; only the ack starts cold.
      assert has_element?(view, "#resource-cpu-cores[value='1']")
      assert has_element?(view, "#resource-memory-mb[value='512']")
      refute has_element?(view, "#below-recommendation-warning")
    end
  end

  # Oct 20's silent failure (#175, landed as #177): ResolveCluster
  # rejects the create on :cluster_id — a field no step renders an
  # input for and no bounce-back exists — so the submit left only a
  # flash about "errors above" with nothing above. #deploy-errors now
  # carries every such message. (Walked through the resources step
  # since #180 inserted it before the name step.)
  test "a create rejection on a step-invisible field renders on the name step (cluster row missing)",
       %{conn: conn, app: app, version: version, cluster: cluster} do
    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
    to_step_2(view, version)
    to_step_3(view, %{})
    to_step_4(view)

    # The cluster row vanishes between the env gate and submit — the
    # half-seeded-env shape.
    Ash.destroy!(cluster, authorize?: false)

    html =
      view
      |> form("#deploy-form", instance: %{name: "Orphan"})
      |> render_submit()

    assert html =~ "no cluster is configured"
    assert has_element?(view, "#deploy-errors")
    assert has_element?(view, "#deploy-form")
  end
end
