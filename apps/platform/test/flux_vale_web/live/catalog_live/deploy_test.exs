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
  alias FluxVale.Clients.K8s.Resources.Middleware
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
        # #221: the wizard is rungs-only, so the fixture's default
        # allocation must sit on the sliders' ladders to open AT the
        # recommendation — 1024 MB is the memory ladder's second rung.
        default_memory_mb: 1024,
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
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
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
  # (slider indices, the rungs' positions, as the range inputs carry
  # them); the current allocation flows when omitted.
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
    _html = render_click(view, "resources-change", %{"resources" => %{"memory_mb" => "0"}})

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

    # The S8 a11y follow-up: the error list is an alert region that
    # takes focus on mount (the error shape is map-level — every
    # message hangs off :env_vars — so per-field aria-invalid has
    # nothing honest to point at; that residual is declared on the PR).
    assert has_element?(view, "#env-errors[role='alert']")
    assert has_element?(view, "#env-errors[tabindex='-1']")
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
    assert instance.memory_mb == 1024
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
    assert nil_instance.memory_mb == 1024
    assert nil_instance.storage_gb == 10
    assert nil_instance.size_id

    assert instance.name == "Ghost"
    assert instance.cpu_cores == Decimal.new("0.5")
    assert instance.memory_mb == 1024
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
    render_click(view, "resources-change", %{"resources" => %{"memory_mb" => "0"}})

    render_click(view, "back-resources", %{})

    assert has_element?(view, "#resource-cpu-cores[value='1']")
    assert has_element?(view, "#resource-memory-mb[value='0']")
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

    test "the sliders step the ladder's rungs by index", %{view: view} do
      # A range input can only carry a uniform step, so it addresses
      # the rungs by position (#221): min 0, max the last rung's
      # index, step 1. The native semantics are then the detents —
      # one arrow press is one rung, Home/End are the ladder's ends,
      # and the browser quantizes the thumb to whole rungs during a
      # drag: it never rests between rungs.
      assert has_element?(view, "#resource-cpu-cores[min='0'][max='6'][step='1']")
      assert has_element?(view, "#resource-memory-mb[min='0'][max='6'][step='1']")
      assert has_element?(view, "#resource-storage-gb[min='0'][max='6'][step='1']")
    end

    test "the sliders carry accessible labels and a unit-announcing readout", %{view: view} do
      html = render(view)

      assert html =~ ~s(for="resource-cpu-cores")
      assert html =~ ~s(aria-valuetext="0.5 cores")
      assert html =~ ~s(aria-valuetext="1024 MB")
      assert html =~ ~s(aria-valuetext="10 GB")
    end

    test "the tick row labels the rungs and highlights the one under the thumb", %{view: view} do
      # Where you stopped must be unmistakable (#221): every rung is a
      # labeled, equally spaced tick (the index scale is equal-width),
      # the active one carries data-active, and the readout names the
      # rung's value.
      for rung <- ~w(0.25 0.5 1 2 4 6 8) do
        assert has_element?(view, "#resource-cpu-cores-ticks [data-value='#{rung}']", rung)
      end

      for rung <- ~w(512 1024 2048 4096 8192 12288 16384) do
        assert has_element?(view, "#resource-memory-mb-ticks [data-value='#{rung}']", rung)
      end

      for rung <- ~w(5 10 20 50 100 200 400) do
        assert has_element?(view, "#resource-storage-gb-ticks [data-value='#{rung}']", rung)
      end

      # The fixture's defaults sit on the ladder, so entry shows each
      # dimension's recommended rung active — thumb, tick, readout all
      # describe one allocation.
      assert has_element?(
               view,
               "#resource-cpu-cores-ticks [data-value='0.5'][data-active='true']"
             )

      assert has_element?(
               view,
               "#resource-memory-mb-ticks [data-value='1024'][data-active='true']"
             )

      assert has_element?(
               view,
               "#resource-storage-gb-ticks [data-value='10'][data-active='true']"
             )

      # One index move — an arrow press's worth — walks the highlight
      # and the readout to the next rung together.
      view
      |> form("#resources-form", resources: %{cpu_cores: "2"})
      |> render_change()

      assert has_element?(view, "#resource-cpu-cores[value='2']")
      assert has_element?(view, "#resource-cpu-cores-ticks [data-value='1'][data-active='true']")

      refute has_element?(
               view,
               "#resource-cpu-cores-ticks [data-value='0.5'][data-active='true']"
             )

      assert render(view) =~ ~s(aria-valuetext="1 cores")
    end

    test "the rungs are the seeded ladder's per-dimension values", %{view: view} do
      # The picker's contract (the comment on resource_dimensions/0):
      # the arrays ARE the seeds' distinct per-dimension values — the
      # quick picks and the sliders offer the same allocations, so a
      # preset is always a reachable thumb position and vice versa. A
      # seed edit that breaks this hides that size from the quick picks
      # (representable_size?/1); the arrays grow only deliberately.
      sizes = Ash.read!(Size, authorize?: false)
      assert sizes != []

      for {field, id} <- [
            {:cpu_cores, "resource-cpu-cores"},
            {:memory_mb, "resource-memory-mb"},
            {:storage_gb, "resource-storage-gb"}
          ] do
        expected =
          sizes
          |> Enum.map(fn size ->
            case Map.get(size, field) do
              %Decimal{} = decimal -> Decimal.to_string(decimal, :normal)
              int -> Integer.to_string(int)
            end
          end)
          |> Enum.uniq()
          |> Enum.sort_by(&Decimal.new/1, Decimal)

        # The ticks' DOM order is the ladder's order — extracted from
        # the one scoped container, not the page.
        rendered =
          view
          |> element("##{id}-ticks")
          |> render()
          |> then(&Regex.scan(~r/data-value="([^"]+)"/, &1))
          |> Enum.map(&Enum.at(&1, 1))

        assert rendered == expected

        for size <- sizes do
          assert has_element?(view, "[data-testid='preset-#{size.slug}']")
        end
      end
    end

    test "an off-ladder version default floors to the next rung at or above it",
         %{conn: conn} do
      # ADR-0027 can put an allocation the ladder can't express on a
      # version's defaults (the admin path); rungs-only (#221) must
      # keep the app's minimum satisfiable, so the initial allocation
      # clamps UP — 0.1 CPU floors to 0.25, 300 MB to 512, 7 GB to 10.
      # (#195's nearest-step snap could land UNDER the default and open
      # the step already warning; the floor never does.)
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

      # The readout announces the floored rung, not the admin's raw
      # default; the thumbs sit on rung indices 0/0/1.
      assert has_element?(view, "#resource-cpu-cores[value='0']")
      assert has_element?(view, "#resource-memory-mb[value='0']")
      assert has_element?(view, "#resource-storage-gb[value='1']")

      html = render(view)
      assert html =~ ~s(aria-valuetext="0.25 cores")
      assert html =~ ~s(aria-valuetext="512 MB")
      assert html =~ ~s(aria-valuetext="10 GB")
      refute html =~ ~s(aria-valuetext="300 MB")

      # Floored up, the entry allocation is never below the app's
      # stated minimum: no heads-up mounts on the first render. (The
      # "recommends …" copy above still names the app's true default —
      # that is a statement about the app, not about what the picker
      # can offer; the controls and their readouts are what must never
      # disagree with the submitted value.)
      refute has_element?(view, "#below-recommendation-warning")

      # Not the recommendation either (the defaults are off-ladder):
      # the price follows the floored allocation by the anchor formula.
      assert has_element?(view, "[data-testid='resources-price']", "$2.99/mo · billed hourly")

      # An unrelated event re-renders from state without forking the
      # rung the inputs carry.
      render_change(view, "resources-change", %{"resources" => %{"memory_mb" => "0"}})

      assert has_element?(view, "#resource-cpu-cores[value='0']")
      assert has_element?(view, "#resource-memory-mb[value='0']")
    end

    test "a default above the ladder's top rung clamps down to it", %{conn: conn} do
      # Past the ladder's end there is no at-or-above rung: the floor
      # lands on the top rung (8 CPU, #233's new top), which IS under
      # the app's stated 10-core minimum — the heads-up honestly mounts
      # and gates, and the user cannot improve it (8 is the most the
      # wizard offers; a 10-core allocation is legal at the API — the
      # Instance constraints, the authoritative say at save — this
      # step just never offers it).
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

      assert has_element?(view, "#resource-cpu-cores[value='6']")
      assert render(view) =~ ~s(aria-valuetext="8 cores")
      assert has_element?(view, "#below-recommendation-warning")
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

      # And a crafted pick of it still can't smuggle in an unrunged
      # allocation (the handler looks it up in the filtered list).
      render_click(view, "pick-size", %{"slug" => off_ladder.slug})

      assert has_element?(view, "#resource-memory-mb[value='1']")

      # A size numerically ON the ladder but written with trailing
      # zeros (1.0 cores, not 1) is still one number with the rung —
      # decimal_string/1 normalizes before the string membership
      # check, and the pick's state lands on the rung's exact string.
      trailing =
        Size.create!(
          %{
            slug: "trailing-#{System.unique_integer([:positive])}",
            cpu_cores: Decimal.new("1.0"),
            memory_mb: 2048,
            storage_gb: 20,
            monthly_cents: 621,
            stopped_monthly_cents: 68
          },
          authorize?: false
        )

      {:ok, fresh, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(fresh, version)
      to_step_3(fresh)

      assert has_element?(fresh, "[data-testid='preset-#{trailing.slug}']")

      render_click(fresh, "pick-size", %{"slug" => trailing.slug})

      assert has_element?(fresh, "#resource-cpu-cores[value='2']")
      assert render(fresh) =~ ~s(aria-valuetext="1 cores")
    end

    test "the seeded sizes render as quick picks, the recommendation called out",
         %{view: view, version: version} do
      for slug <- ~w(micro small medium standard plus pro ultra max) do
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
      # `standard` is 1 CPU / 2048 MB / 20 GB — rung index 2 on all
      # three ladders — a custom allocation for this fixture's version
      # (0.5/1024/10).
      view
      |> element("[data-testid='preset-standard']")
      |> render_click()

      assert has_element?(view, "#resource-cpu-cores[value='2']")
      assert has_element?(view, "#resource-memory-mb[value='2']")
      assert has_element?(view, "#resource-storage-gb[value='2']")

      # The price follows the allocation (#186): the anchor formula at
      # 1 CPU / 2048 MB / 20 GB — which the seeded table pins at the
      # standard size's $6.21 (B′) — never this fixture's $1.00 size price.
      assert has_element?(view, "[data-testid='resources-price']", "$6.21/mo · billed hourly")
      refute has_element?(view, "[data-testid='resources-price']", "$1.00/mo · billed hourly")

      assert has_element?(view, "[data-testid='preset-standard'][aria-pressed='true']")
    end

    test "the #233 top rungs price through the curve at the ladder's new top", %{view: view} do
      # `max` is 8 CPU / 16384 MB / 400 GB — rung index 6, the top of
      # all three ladders (#233). Picking it parks every thumb on the
      # new top rung and prices at the seeded max cents ($28.95, B′)
      # — the curve's own number at that allocation, pinned by the
      # calibration tests; a recommendation-priced or fixture-priced
      # display here would mean the top rungs aren't really offered.
      view
      |> element("[data-testid='preset-max']")
      |> render_click()

      assert has_element?(view, "#resource-cpu-cores[value='6']")
      assert has_element?(view, "#resource-memory-mb[value='6']")
      assert has_element?(view, "#resource-storage-gb[value='6']")

      html = render(view)
      assert html =~ ~s(aria-valuetext="8 cores")
      assert html =~ ~s(aria-valuetext="16384 MB")
      assert html =~ ~s(aria-valuetext="400 GB")

      assert has_element?(view, "[data-testid='resources-price']", "$28.95/mo · billed hourly")

      # Above the recommendation: no heads-up, no ack gate.
      refute has_element?(view, "#below-recommendation-warning")
    end

    test "a preset above the recommendation never warns", %{view: view} do
      view
      |> element("[data-testid='preset-pro']")
      |> render_click()

      refute has_element?(view, "#below-recommendation-warning")
      assert has_element?(view, "[data-testid='resources-price']")
    end

    test "a size below the recommendation trips the heads-up + ack flow", %{view: view} do
      # `micro` (0.25/512/5) is below this fixture's 0.5/1024/10 on CPU
      # and storage — enough for the gate.
      view
      |> element("[data-testid='preset-micro']")
      |> render_click()

      assert has_element?(view, "#below-recommendation-warning")
      assert has_element?(view, "#below-recommendation-ack")
    end

    test "a crafted index that names no rung changes nothing", %{view: view} do
      # The sliders emit positions; the LiveView owns the values. An
      # out-of-range, negative or fractional index can't name a rung,
      # so the payload is silence (pick-size's unknown-slug posture):
      # a hostile client gets neither a crash nor a bogus allocation.
      render_change(view, "resources-change", %{
        "resources" => %{"cpu_cores" => "99", "memory_mb" => "-1", "storage_gb" => "1.5"}
      })

      assert has_element?(view, "#resource-cpu-cores[value='1']")
      assert has_element?(view, "#resource-memory-mb[value='1']")
      assert has_element?(view, "#resource-storage-gb[value='1']")

      # Non-numeric, and a non-string a crafted event can smuggle
      # where a browser only sends strings — both are equally nameless.
      render_change(view, "resources-change", %{"resources" => %{"cpu_cores" => "zero"}})
      render_change(view, "resources-change", %{"resources" => %{"memory_mb" => 512}})

      assert has_element?(view, "#resource-cpu-cores[value='1']")
      assert has_element?(view, "#resource-memory-mb[value='1']")
      assert has_element?(view, "#resources-form")
    end

    test "a crafted unknown preset slug changes nothing", %{view: view} do
      render_click(view, "pick-size", %{"slug" => "does-not-exist"})

      # The rendered buttons can't produce one; a hostile client gets
      # silence, not a crash and not a bogus allocation.
      assert has_element?(view, "#resource-cpu-cores[value='1']")
      assert has_element?(view, "#resource-memory-mb[value='1']")
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
      # The version's defaults (0.5 CPU / 1024 MB / 10 GB) prefill the
      # controls — rung indices 1/1/1 — and label the recommendation.
      assert has_element?(view, "#resource-cpu-cores[value='1']")
      assert has_element?(view, "#resource-memory-mb[value='1']")
      assert has_element?(view, "#resource-storage-gb[value='1']")
      assert has_element?(view, "[data-testid='recommended-allocation']")

      # At the recommendation: no warning, no ack, the size price
      # (the fixture's fabricated size — the seeded size/formula
      # equivalence is the calibration tests' contract, not this
      # fixture's).
      refute has_element?(view, "#below-recommendation-warning")
      assert has_element?(view, "[data-testid='resources-price']", "$1.00/mo · billed hourly")

      # The estimate tracks the inputs live (#186's done-when): one
      # rung up (cpu index 2 = 1 core) reprices, and back at the
      # recommendation the size price returns.
      view
      |> form("#resources-form", resources: %{cpu_cores: "2"})
      |> render_change()

      assert has_element?(view, "[data-testid='resources-price']", "$4.65/mo · billed hourly")

      view
      |> form("#resources-form", resources: %{cpu_cores: "1"})
      |> render_change()

      assert has_element?(view, "[data-testid='resources-price']", "$1.00/mo · billed hourly")

      to_step_4(view)

      assert has_element?(view, "[data-testid='price-summary']", "$1.00/mo · billed hourly")
    end

    test "an above-recommendation allocation deploys unrestricted at the formula price",
         %{user: user, view: view} do
      stub_k8s()

      # Rung picks over the 0.5/1024/10 recommendation: cpu index 2
      # (1 core) and storage index 2 (20) above it, memory left at its
      # default rung — the warning is any dimension strictly under, and
      # none is.
      view
      |> form("#resources-form",
        resources: %{cpu_cores: "2", memory_mb: "1", storage_gb: "2"}
      )
      |> render_change()

      refute has_element?(view, "#below-recommendation-warning")

      # The live estimate follows the allocation (#186): the anchor
      # formula at 1 CPU / 1024 MB / 20 GB, on the resources step and
      # carried to the name step. No interim copy remains.
      assert has_element?(view, "[data-testid='resources-price']", "$4.92/mo · billed hourly")

      to_step_4(view)

      assert has_element?(view, "[data-testid='price-summary']", "$4.92/mo · billed hourly")
      refute render(view) =~ "billed at the recommended size"

      view
      |> form("#deploy-form", instance: %{name: "Bigger"})
      |> render_submit()

      assert_redirect(view)

      [instance] = Instance.list_for_actor!(actor: user)

      assert instance.cpu_cores == Decimal.new("1")
      assert instance.memory_mb == 1024
      assert instance.storage_gb == 20

      # The ledger charges exactly what the wizard showed: the formula
      # cents snapshot at create (no size for a custom allocation).
      assert instance.size_id == nil
      assert instance.grandfathered_monthly_cents == 492
      assert instance.grandfathered_stopped_monthly_cents == 68
      assert instance.grandfathered_until
    end

    test "a below-recommendation allocation warns and gates on an explicit acknowledgment",
         %{user: user, view: view} do
      stub_k8s()

      # Storage one rung under the default (index 0 = 5 GB): below the
      # recommendation on that dimension.
      view
      |> form("#resources-form", resources: %{storage_gb: "0"})
      |> render_change()

      assert has_element?(view, "#below-recommendation-warning")
      assert render(view) =~ "it may run slowly or fail"

      # A channel-level continue without the ack stays put (the disabled
      # button is client-side only).
      html = render_click(view, "resources-continue", %{"resources" => %{"storage_gb" => "0"}})

      assert html =~ "Acknowledge the below-recommendation warning"
      assert has_element?(view, "#resources-form")

      # The estimate follows the below-recommendation allocation too —
      # the ack flow prices, it doesn't hide.
      assert has_element?(view, "[data-testid='resources-price']", "$3.93/mo · billed hourly")

      # The ack rides the form; Continue proceeds and the deploy lands
      # at the chosen (lower) allocation.
      to_step_4(view, %{storage_gb: "0", below_ack: "on"})

      view
      |> form("#deploy-form", instance: %{name: "Smaller"})
      |> render_submit()

      assert_redirect(view)

      [instance] = Instance.list_for_actor!(actor: user)

      assert instance.memory_mb == 1024
      assert instance.cpu_cores == Decimal.new("0.5")
      assert instance.storage_gb == 5

      # Formula-priced: the below-recommendation snapshot.
      assert instance.size_id == nil
      assert instance.grandfathered_monthly_cents == 393
    end

    test "a back-nav round trip keeps the chosen allocation", %{view: view} do
      view
      |> form("#resources-form", resources: %{cpu_cores: "2", memory_mb: "2"})
      |> render_change()

      view
      |> element("button[phx-click='back-env']")
      |> render_click()

      view
      |> element("#env-form")
      |> render_submit(%{env_values: %{}})

      # The env detour preserved the rungs; only the ack starts cold.
      assert has_element?(view, "#resource-cpu-cores[value='2']")
      assert has_element?(view, "#resource-memory-mb[value='2']")
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

    # The step-4 list carries the same alert posture as the env step's
    # (hostile-357 F4 pins it: a future edit strips this silently).
    assert has_element?(view, "#deploy-errors[role='alert']")
    assert has_element?(view, "#deploy-errors[tabindex='-1']")
    assert has_element?(view, "#deploy-form")
  end
end
