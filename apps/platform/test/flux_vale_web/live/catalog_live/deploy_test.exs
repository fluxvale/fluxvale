defmodule FluxValeWeb.CatalogLive.DeployTest do
  @moduledoc false

  # The deploy stepper (#74): version → env (schema-rendered) → name →
  # create + auto-deploy. K8s is stubbed (Mimic, v1's canonical pattern)
  # because Oban runs inline in tests — the deploy trigger executes
  # synchronously on submit.
  # Sync: a seed writes shared rows, so it must not overlap another test.

  use FluxValeWeb.ConnCase, async: false
  use Mimic

  import FluxVale.TestSupport.NoK8sLeaks
  import Phoenix.LiveViewTest

  alias FluxVale.Accounts
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
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  require Ash.Query

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
    # The wizard's ladders and quick picks are the seeded sizes, so this
    # file seeds them up front — BEFORE the fixtures, because the
    # fixture's version references its own fabricated size and
    # seed_pricing!/0's guarded delete (#399) refuses to run while any
    # version references a size absent from the YAML. Seeded for every
    # test here (the picker tests pin against them; the other describes
    # simply render the six quick picks they were already stepping past).
    :ok = FluxVale.Seeds.seed_pricing!()

    {user, conn} = SessionHelpers.user_with_session(conn)
    cluster = InstanceFixtures.local_cluster!()

    version =
      InstanceFixtures.app_version!(
        configurable_env_vars: @schema,
        # #221: the wizard is rungs-only, so the fixture's default
        # allocation must sit on the sliders' ladders to open AT the
        # recommendation — 1024 MB is the memory ladder's second rung.
        # #558: the fixture's size prices compute only (100¢); the
        # version's 10 GB storage default prices on the axis (40¢), so
        # the at-recommendation rate is $1.40/mo throughout this file.
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
             "$1.40/mo · billed hourly"
           )

    assert html =~ "published"
  end

  # #179's surface audit: the stepper renders across all three steps
  # and flashes after events — none of it may name the platform under
  # the hood.
  test "every stepper step and flash renders k8s-free", %{conn: conn, app: app, version: version} do
    {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")

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

    # The name step carries ADR-0028's estimate for the picked version:
    # the size's 100¢ compute rate plus the axis at the 10 GB default.
    assert has_element?(view, "[data-testid='price-summary']", "$1.40/mo · billed hourly")

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

  # The band's org picker (#408): where the instance lands. The picker
  # rides the create's organization_id argument — member-fenced by the
  # create policy, personal-org-defaulted when untouched.
  describe "the org picker (#408)" do
    test "lists the actor's orgs and defaults to Personal", %{conn: conn, user: user, app: app} do
      {:ok, team} =
        Accounts.create_organization(user, %{
          name: "Wizard Team",
          slug: "wizard-team-#{System.unique_integer([:positive])}"
        })

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")

      personal = personal_org_id!(user)

      assert has_element?(view, "[data-testid='deploy-org-picker']")
      assert render(element(view, "#deploy-org option[value='#{personal}']")) =~ "Personal"
      assert has_element?(view, "#deploy-org option[value='#{team.id}']", "Wizard Team")

      # The default is the personal org — the untouched picker changes
      # nothing about the create's own default.
      assert render(element(view, "#deploy-org option[value='#{personal}']")) =~ "selected"

      refute render(element(view, "#deploy-org option[value='#{team.id}']")) =~ "selected"
    end

    test "the pick rides the create — the instance lands in the named org", %{
      conn: conn,
      user: user,
      app: app,
      version: version
    } do
      stub_k8s()

      {:ok, team} =
        Accounts.create_organization(user, %{
          name: "Wizard Team",
          slug: "wizard-team-#{System.unique_integer([:positive])}"
        })

      # The named org's wallet is what the create gate reads (#124).
      BillingFixtures.funded_wallet!(org: team)

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")

      render_click(view, "pick-org", %{"org_id" => team.id})

      to_step_2(view, version)
      to_step_3(view)
      to_step_4(view)

      view
      |> form("#deploy-form", instance: %{name: "Team Forgejo"})
      |> render_submit()

      assert_redirect(view)

      instance =
        Instance
        |> Ash.Query.filter(name == "Team Forgejo")
        |> Ash.read_one!(authorize?: false)

      assert instance.organization_id == team.id
    end

    test "an untouched picker keeps the personal-org default", %{
      conn: conn,
      user: user,
      app: app,
      version: version
    } do
      stub_k8s()
      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")

      to_step_2(view, version)
      to_step_3(view)
      to_step_4(view)

      view
      |> form("#deploy-form", instance: %{name: "Personal Forgejo"})
      |> render_submit()

      assert_redirect(view)

      instance =
        Instance
        |> Ash.Query.filter(name == "Personal Forgejo")
        |> Ash.read_one!(authorize?: false)

      assert instance.organization_id == personal_org_id!(user)
    end

    test "a crafted pick changes nothing", %{conn: conn, user: user, app: app} do
      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")

      # An org id the picker never offered (the rendered options can't
      # produce one): the current pick stays, nothing crashes.
      render_click(view, "pick-org", %{"org_id" => Ecto.UUID.generate()})

      personal = personal_org_id!(user)

      assert render(element(view, "#deploy-org option[value='#{personal}']")) =~ "selected"
    end
  end

  defp personal_org_id!(user) do
    {:ok, org} = Accounts.personal_org_for_user(user.id, actor: user)
    org.id
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
    assert has_element?(view, "[data-testid='resources-price']", "$1.40/mo · billed hourly")
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
      # The seeded sizes come from the file's outer setup (before the
      # fixtures — the guarded delete's ordering note there).
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
      assert has_element?(view, "#resource-cpu-cores[min='0'][max='4'][step='1']")
      assert has_element?(view, "#resource-memory-mb[min='0'][max='4'][step='1']")
      assert has_element?(view, "#resource-storage-gb[min='0'][max='5'][step='1']")
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
      for rung <- ~w(0.25 0.5 1 2 4) do
        assert has_element?(view, "#resource-cpu-cores-ticks [data-value='#{rung}']", rung)
      end

      for rung <- ~w(512 1024 2048 4096 8192) do
        assert has_element?(view, "#resource-memory-mb-ticks [data-value='#{rung}']", rung)
      end

      for rung <- ~w(5 10 20 50 100) do
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

      assert render(view) =~ ~s(aria-valuetext="1 core")
    end

    test "the compute rungs are the seeded sizes' distinct values, storage its own axis",
         %{view: view} do
      # The compute ladders' contract (the comment on
      # resource_dimensions/0): the arrays ARE the seeds' distinct
      # per-dimension compute values — the quick picks and the sliders
      # offer the same compute shapes, so a preset's compute is always
      # a reachable thumb position and vice versa. A seed edit that
      # breaks this hides that size from the quick picks
      # (representable_size?/1); the arrays grow only deliberately.
      # Storage is its own axis (#558): its ladder is the offered
      # per-GB range — the same five paid rungs the axis rate table
      # prices (24/40/68/135/228¢ B′) — plus the 0 rung (#576:
      # stateless apps ship an honest empty storage axis), not
      # anything a compute class carries.
      sizes = Ash.read!(Size, authorize?: false)
      assert sizes != []

      for {field, id} <- [{:cpu_cores, "resource-cpu-cores"}, {:memory_mb, "resource-memory-mb"}] do
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
      end

      storage_ticks =
        view
        |> element("#resource-storage-gb-ticks")
        |> render()
        |> then(&Regex.scan(~r/data-value="([^"]+)"/, &1))
        |> Enum.map(&Enum.at(&1, 1))

      # Storage is its own axis (#558): its ladder is the offered
      # per-GB range plus the 0 rung (#576's stateless-app floor —
      # an external-database app needs no volume at all).
      assert storage_ticks == ~w(0 5 10 20 50 100)

      for size <- sizes do
        assert has_element?(view, "[data-testid='preset-#{size.slug}']")
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
      # default; the thumbs sit on rung indices 0/0/2 (10 GB — index 2
      # since the #576 zero rung joined the storage ladder).
      assert has_element?(view, "#resource-cpu-cores[value='0']")
      assert has_element?(view, "#resource-memory-mb[value='0']")
      assert has_element?(view, "#resource-storage-gb[value='2']")

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

    test "a zero-storage version default opens the picker at the 0 rung", %{conn: conn} do
      # #576's stateless shape: a version whose honest storage default
      # is 0 (every row lives in the owner's database) opens the picker
      # AT 0 — the pre-#576 ladder had no 0 rung, so the wizard would
      # have floored the default up to 5 GB and billed an unused
      # volume. The compute defaults sit on the ladder, so the storage
      # thumb is the assertion under test.
      version =
        InstanceFixtures.app_version!(
          default_cpu_cores: Decimal.new("0.25"),
          default_memory_mb: 512,
          default_storage_gb: 0,
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

      # The storage thumb sits on rung index 0 (0 GB), not the old
      # 5 GB floor; the price is the fixture size row's own cents
      # (compute only — 0 GB adds nothing, the pre-#576 floor would
      # have billed 5 GB on top).
      assert has_element?(view, "#resource-storage-gb[value='0']")

      html = render(view)
      assert html =~ ~s(aria-valuetext="0 GB")

      assert has_element?(view, "[data-testid='resources-price']", "$1.00/mo · billed hourly")
    end

    test "a default above the ladder's top rung clamps down to it", %{conn: conn} do
      # Past the ladder's end there is no at-or-above rung: the floor
      # lands on the top rung (4 CPU — #399 trimmed the ladder to the
      # six shipped sizes and pro is the top), which IS under the app's
      # stated 10-core minimum — the heads-up honestly mounts and
      # gates, and the user cannot improve it (4 is the most the wizard
      # offers; a 10-core allocation is legal at the API — the
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

      assert has_element?(view, "#resource-cpu-cores[value='4']")
      assert render(view) =~ ~s(aria-valuetext="4 cores")
      assert has_element?(view, "#below-recommendation-warning")
    end

    test "an admin compute allocation the ladders can't express is not offered as a quick pick",
         %{conn: conn, app: app, version: version} do
      # ADR-0027 lets an admin add any Size the schema accepts; a preset
      # that its own wizard would refuse or silently clamp is worse than
      # none, so representable_size?/1 filters it out of the picks.
      # #558: only the compute rungs gate the filter — a size carries
      # nothing else to be off-ladder about.
      off_ladder =
        Size.create!(
          %{
            slug: "off-ladder-#{System.unique_integer([:positive])}",
            cpu_cores: Decimal.new("0.3"),
            memory_mb: 300,
            monthly_cents: 123
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
            monthly_cents: 621
          },
          authorize?: false
        )

      {:ok, fresh, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(fresh, version)
      to_step_3(fresh)

      assert has_element?(fresh, "[data-testid='preset-#{trailing.slug}']")

      render_click(fresh, "pick-size", %{"slug" => trailing.slug})

      assert has_element?(fresh, "#resource-cpu-cores[value='2']")
      assert render(fresh) =~ ~s(aria-valuetext="1 core")
    end

    test "the seeded sizes render as quick picks, the recommendation called out",
         %{view: view, version: version} do
      for slug <- ~w(micro small medium standard plus pro) do
        assert has_element?(view, "[data-testid='preset-#{slug}']")
      end

      # #558: the sub-line is the size's compute shape plus a storage
      # callout — the size prices compute only, and the price beside
      # it is that compute rate ($3.69 = medium's seeded cents).
      assert has_element?(
               view,
               "[data-testid='preset-medium']",
               "0.5 CPU · 1024 MB + your storage"
             )

      assert has_element?(view, "[data-testid='preset-medium']", "$3.69/mo · billed hourly")

      # The version's own recommended size is called out (the fixture's
      # fabricated size — loaded here, it rides the fixture unloaded).
      recommended =
        Ash.load!(version, :recommended_size, authorize?: false).recommended_size.slug

      assert has_element?(view, "#preset-#{recommended}", "recommended")

      # The fixture fabricates its size to match the version's compute
      # defaults, so the recommendation is also the pressed quick pick —
      # a meaningful `aria-pressed="true"`, not just the attribute's
      # presence. Pressed compares compute only (#558): medium shares
      # the shape, so it reads pressed too — honestly, both land the
      # same compute.
      assert has_element?(view, "#preset-#{recommended}[aria-pressed='true']")
      assert has_element?(view, "#preset-medium[aria-pressed='true']")
    end

    test "a preset pick moves compute and leaves the storage rung alone", %{view: view} do
      # #558 pin: storage first — rung index 4 (50 GB; index 0 is the
      # #576 zero rung) — then a quick pick. The pick moves only the
      # compute sliders; the storage thumb stays exactly where the
      # user left it.
      view
      |> form("#resources-form", resources: %{storage_gb: "4"})
      |> render_change()

      view
      |> element("[data-testid='preset-plus']")
      |> render_click()

      # plus is 2 CPU / 4096 MB — rung index 3 on both compute ladders.
      assert has_element?(view, "#resource-cpu-cores[value='3']")
      assert has_element?(view, "#resource-memory-mb[value='3']")
      assert render(view) =~ ~s(aria-valuetext="2 cores")
      assert render(view) =~ ~s(aria-valuetext="4096 MB")

      # 50 GB, untouched by the pick.
      assert has_element?(view, "#resource-storage-gb[value='4']")
      assert render(view) =~ ~s(aria-valuetext="50 GB")
    end

    test "picking a size moves compute and reprices from the curve", %{view: view} do
      # `standard` is 1 CPU / 2048 MB — rung index 2 on both compute
      # ladders — a custom compute for this fixture's version
      # (0.5/1024). The storage rung stays at the version's 10 GB
      # default (index 2, the user hadn't moved it).
      view
      |> element("[data-testid='preset-standard']")
      |> render_click()

      assert has_element?(view, "#resource-cpu-cores[value='2']")
      assert has_element?(view, "#resource-memory-mb[value='2']")
      assert has_element?(view, "#resource-storage-gb[value='2']")

      # The price follows the allocation (#186): the anchor formula at
      # 1 CPU / 2048 MB plus the 10 GB axis rate — compute 553¢ (the
      # seeded standard rate, B′) + 40¢ = $5.93 — never this fixture's
      # $1.40 size-anchored rate.
      assert has_element?(view, "[data-testid='resources-price']", "$5.93/mo · billed hourly")
      refute has_element?(view, "[data-testid='resources-price']", "$1.40/mo · billed hourly")

      assert has_element?(view, "[data-testid='preset-standard'][aria-pressed='true']")
    end

    test "the top compute rung prices through the size rate plus the axis", %{view: view} do
      # `pro` is 4 CPU / 8192 MB — rung index 4, the top of both
      # compute ladders (#399 trimmed the two proposed rungs above
      # it). Picking it parks the compute thumbs on the top rungs —
      # storage stays at the version's 10 GB default — and prices at
      # the seeded pro compute rate plus the axis ($13.79 + $0.40 =
      # $14.19); a recommendation-priced or fixture-priced display
      # here would mean the top rung isn't really offered.
      view
      |> element("[data-testid='preset-pro']")
      |> render_click()

      assert has_element?(view, "#resource-cpu-cores[value='4']")
      assert has_element?(view, "#resource-memory-mb[value='4']")
      assert has_element?(view, "#resource-storage-gb[value='2']")

      html = render(view)
      assert html =~ ~s(aria-valuetext="4 cores")
      assert html =~ ~s(aria-valuetext="8192 MB")
      assert html =~ ~s(aria-valuetext="10 GB")

      assert has_element?(view, "[data-testid='resources-price']", "$14.19/mo · billed hourly")

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
      assert has_element?(view, "#resource-storage-gb[value='2']")

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
      assert has_element?(view, "#resource-storage-gb[value='2']")
      assert has_element?(view, "[data-testid='recommended-allocation']")

      # #558's intro copy: compute and storage named as two axes.
      assert render(view) =~ "0.5 CPU · 1024 MB compute and 10 GB storage"
      assert render(view) =~ "for this version. Allocate more, or less at your own risk."

      # At the recommendation: no warning, no ack, and the price is the
      # recommended size's compute rate plus the storage axis at the
      # default rung — the fixture's 100¢ size + 40¢ axis = $1.40 (the
      # seeded size/formula equivalence is the calibration tests'
      # contract, not this fixture's).
      refute has_element?(view, "#below-recommendation-warning")
      assert has_element?(view, "[data-testid='resources-price']", "$1.40/mo · billed hourly")

      # The estimate tracks the inputs live (#186's done-when): one
      # rung up (cpu index 2 = 1 core) is custom compute, so the
      # formula takes the whole allocation — 424¢ compute + 40¢ axis
      # (the axes round independently since #558, one cent under the
      # old round-the-sum figure) — and back at the recommendation the
      # size-anchored rate returns.
      view
      |> form("#resources-form", resources: %{cpu_cores: "2"})
      |> render_change()

      assert has_element?(view, "[data-testid='resources-price']", "$4.64/mo · billed hourly")

      view
      |> form("#resources-form", resources: %{cpu_cores: "1"})
      |> render_change()

      assert has_element?(view, "[data-testid='resources-price']", "$1.40/mo · billed hourly")

      to_step_4(view)

      assert has_element?(view, "[data-testid='price-summary']", "$1.40/mo · billed hourly")
    end

    test "moving only storage keeps the size-anchored recommended price path", %{view: view} do
      # #558 pin: compute stays on the recommendation (0.5/1024), so
      # the price stays on the size arm — the size's compute rate plus
      # the axis at each rung — never flipping to custom-allocation
      # formula pricing (which would read $3.93 at 5 GB: the curve's
      # own compute term, 369¢, is not this version's size rate).
      view
      |> form("#resources-form", resources: %{storage_gb: "3"})
      |> render_change()

      assert has_element?(view, "[data-testid='resources-price']", "$1.68/mo · billed hourly")

      view
      |> form("#resources-form", resources: %{storage_gb: "1"})
      |> render_change()

      # 100¢ compute + the 5 GB axis rate (24¢) — the axis delta from
      # $1.40, exactly.
      assert has_element?(view, "[data-testid='resources-price']", "$1.24/mo · billed hourly")
      refute has_element?(view, "[data-testid='resources-price']", "$3.93/mo · billed hourly")
    end

    test "an above-recommendation allocation deploys unrestricted at the formula price",
         %{user: user, view: view} do
      stub_k8s()

      # Rung picks over the 0.5/1024/10 recommendation: cpu index 2
      # (1 core) and storage index 3 (20) above it, memory left at its
      # default rung — the warning is any dimension strictly under, and
      # none is.
      view
      |> form("#resources-form",
        resources: %{cpu_cores: "2", memory_mb: "1", storage_gb: "3"}
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

      # Storage one rung under the default (index 1 = 5 GB; index 0 is
      # the #576 zero rung), compute left at the recommendation: below
      # the version default on storage alone — #558 pin: the axis
      # decoupled, the below-recommendation gate did not.
      view
      |> form("#resources-form", resources: %{storage_gb: "1"})
      |> render_change()

      assert has_element?(view, "#below-recommendation-warning")
      assert render(view) =~ "It may run slowly or fail"

      # A channel-level continue without the ack stays put (the disabled
      # button is client-side only).
      html = render_click(view, "resources-continue", %{"resources" => %{"storage_gb" => "1"}})

      assert html =~ "Acknowledge the below-recommendation warning"
      assert has_element?(view, "#resources-form")

      # The estimate follows the below-recommendation allocation too —
      # the ack flow prices, it doesn't hide. Compute never moved, so
      # this stays the size arm: 100¢ compute + the 5 GB axis (24¢).
      assert has_element?(view, "[data-testid='resources-price']", "$1.24/mo · billed hourly")

      # The ack rides the form; Continue proceeds and the deploy lands
      # at the chosen (lower) allocation.
      to_step_4(view, %{storage_gb: "1", below_ack: "on"})

      view
      |> form("#deploy-form", instance: %{name: "Smaller"})
      |> render_submit()

      assert_redirect(view)

      [instance] = Instance.list_for_actor!(actor: user)

      assert instance.memory_mb == 1024
      assert instance.cpu_cores == Decimal.new("0.5")
      assert instance.storage_gb == 5

      # Size-snapshot arm (#558): compute at the recommendation keeps
      # the recommended size — storage rides the axis, so the cents
      # are the compute class's 100¢ plus the 5 GB rate, the same
      # $1.24 the wizard showed (stopped pays the axis alone).
      assert instance.size_id
      assert instance.grandfathered_monthly_cents == 124
      assert instance.grandfathered_stopped_monthly_cents == 24
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

  # #612 S3 (ADR-0045 D4/D5/D6): the wizard's DB-entry behavior — the
  # platform-owned env inputs never render, every slider floors at the
  # version's defaults (the 0-GB rung hides with them), the under-floor
  # quick picks are not offered, and plain copy discloses the share.
  # The fixture's honest defaults (1 CPU / 1024 MB / 10 GB) sit on the
  # ladders, so the floors are exactly those rungs.
  describe "bundled backing services (#612 S3)" do
    setup %{conn: conn} do
      version =
        InstanceFixtures.backing_version!(
          published_at: DateTime.utc_now(),
          configurable_env_vars: %{
            "APP_TOKEN" => %{label: "App token", type: :string, required: false, secret: true}
          }
        )

      app = Ash.load!(version, :app, authorize?: false).app

      {:ok, conn: conn, app: app, version: version}
    end

    test "the env step never renders the platform-owned url inputs and says why", %{
      conn: conn,
      app: app,
      version: version
    } do
      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)

      # D6: the wizard hides what the deploy composes — a typed value
      # would be refused at create, so the input never renders. Every
      # OTHER input stays.
      refute has_element?(view, "#env-DATABASE_URL")
      refute has_element?(view, "#env-REDIS_URL")
      assert has_element?(view, "#env-APP_TOKEN")

      note = render(element(view, "[data-testid='bundled-env-note']"))

      assert note =~ "PostgreSQL 18 and Redis 8 run bundled with this app"
      assert note =~ "FluxVale fills in DATABASE_URL and REDIS_URL automatically at deploy"
    end

    test "every slider floors at the version's defaults — the 0-GB rung hides", %{
      conn: conn,
      app: app,
      version: version
    } do
      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)
      to_step_3(view, %{"APP_TOKEN" => "tok"})

      # The offered rungs start at the floors: the storage ladder loses
      # its 0 and 5 rungs, the compute ladders everything under 1 CPU
      # and 1024 MB.
      assert tick_rungs(view, "resource-cpu-cores") == ~w(1 2 4)
      assert tick_rungs(view, "resource-memory-mb") == ~w(1024 2048 4096 8192)
      assert tick_rungs(view, "resource-storage-gb") == ~w(10 20 50 100)

      # Re-indexed ladders: the inputs' top index shrank with them,
      # and the entry allocation sits on the floor rungs (index 0).
      assert has_element?(view, "#resource-cpu-cores[max='2']")
      assert has_element?(view, "#resource-storage-gb[max='3']")
      assert has_element?(view, "#resource-cpu-cores[value='0']")
      assert has_element?(view, "#resource-memory-mb[value='0']")
      assert has_element?(view, "#resource-storage-gb[value='0']")

      # The below-recommendation ack path is closed for DB entries:
      # the state can't go under the defaults, so the warning never
      # mounts on entry.
      refute has_element?(view, "#below-recommendation-warning")
    end

    test "the resources step discloses the bundled share in plain copy", %{
      conn: conn,
      app: app,
      version: version
    } do
      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)
      to_step_3(view)

      note = render(element(view, "[data-testid='bundled-services-note']"))

      assert note =~ "Includes PostgreSQL 18 and Redis 8"
      assert note =~ "They run inside the instance and share its CPU, memory, and storage."

      # The DB-entry intro drops "less at your own risk" — less isn't
      # offered; the note carries the why instead.
      refute render(view) =~ "or less at your own risk"
    end

    test "a crafted under-floor index lands on the floor, never below it", %{
      conn: conn,
      app: app,
      version: version
    } do
      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)
      to_step_3(view)

      # Index 0 would name 0.25 CPU / 512 MB / 0 GB on the FULL
      # ladders — decoded against the floored ones it names the floor
      # rungs themselves. The hostile client gets the floor, not a
      # smuggled under-allocation (the create's floors are the
      # authoritative gate either way).
      view
      |> form("#resources-form", resources: %{cpu_cores: "0", memory_mb: "0", storage_gb: "0"})
      |> render_change()

      html = render(view)
      assert html =~ ~s(aria-valuetext="1 core")
      assert html =~ ~s(aria-valuetext="1024 MB")
      assert html =~ ~s(aria-valuetext="10 GB")
      refute has_element?(view, "#below-recommendation-warning")
    end

    test "under-floor quick picks are not offered; crafted picks of them change nothing", %{
      conn: conn,
      app: app,
      version: version
    } do
      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)
      to_step_3(view)

      # Floors 1 CPU / 1024 MB hide micro, small, and medium (their
      # compute is under 1 CPU); standard and up stay — a pick the
      # create would refuse is worse than no pick at all.
      for slug <- ~w(micro small medium) do
        refute has_element?(view, "[data-testid='preset-#{slug}']")
      end

      assert has_element?(view, "[data-testid='preset-standard']")
      assert has_element?(view, "[data-testid='preset-plus']")
      assert has_element?(view, "[data-testid='preset-pro']")

      # A crafted pick of a hidden size is silence (the unknown-slug
      # posture): the allocation stays on the floor rungs.
      render_click(view, "pick-size", %{"slug" => "micro"})

      assert has_element?(view, "#resource-cpu-cores[value='0']")
      assert has_element?(view, "#resource-memory-mb[value='0']")
    end

    test "switching to a bundled version after under-allocating resets the allocation", %{
      conn: conn
    } do
      # CodeRabbit (#639): picked rungs belong to the version they
      # were picked for. A user who under-allocates on a plain
      # version, goes back, and picks the bundled one must not carry
      # the stale rungs in — under the bundled floors they would
      # render as a readout no slider can index, reopen the ack path
      # for a DB entry, and die at create.
      plain =
        InstanceFixtures.app_version!(
          default_cpu_cores: Decimal.new("0.25"),
          default_memory_mb: 512,
          default_storage_gb: 10,
          published_at: DateTime.utc_now(),
          configurable_env_vars: %{
            "SMTP_HOST" => %{label: "SMTP host", type: :string, required: false}
          }
        )

      app = Ash.load!(plain, :app, authorize?: false).app

      bundled =
        InstanceFixtures.backing_version!(
          app_id: app.id,
          published_at: DateTime.utc_now(),
          configurable_env_vars: %{
            "APP_TOKEN" => %{label: "App token", type: :string, required: false, secret: true}
          }
        )

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")

      # Under-allocate on the plain version: storage to the 0-GB
      # rung (index 0 on the full ladder — legal there, the ack-gated
      # path the plain entry keeps).
      to_step_2(view, plain)
      to_step_3(view)

      view
      |> form("#resources-form", resources: %{storage_gb: "0"})
      |> render_change()

      assert render(view) =~ ~s(aria-valuetext="0 GB")

      # Back to the version step, forward again on the SAME version:
      # the round trip keeps the choice (the existing pin).
      render_click(element(view, "button[phx-click='back-env']"))
      render_click(element(view, "button[phx-click='back-version']"))
      to_step_2(view, plain)
      to_step_3(view)

      assert render(view) =~ ~s(aria-valuetext="0 GB")

      # Now the switch: back, pick the BUNDLED version. The stale
      # rungs must not ride in — the step reopens at the bundled
      # floors, the 0-GB rung has no index to land on, and the ack
      # path stays closed.
      render_click(element(view, "button[phx-click='back-env']"))
      render_click(element(view, "button[phx-click='back-version']"))
      to_step_2(view, bundled)
      to_step_3(view)

      html = render(view)
      assert html =~ ~s(aria-valuetext="10 GB")
      assert has_element?(view, "#resource-storage-gb[value='0']")
      refute has_element?(view, "#below-recommendation-warning")
    end

    test "the full flow deploys at the floors with the env keys hidden", %{
      conn: conn,
      user: user,
      app: app,
      version: version
    } do
      stub_k8s()

      # The inline deploy's get-or-create reads the backing Secret
      # first (never rotate): absent → not_found → create (stubbed).
      stub(Secret, :get_data, fn _kc, _ns, _name ->
        {:error, %K8s.Error{reason: :not_found}}
      end)

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")

      to_step_2(view, version)
      to_step_3(view, %{"APP_TOKEN" => "tok"})
      to_step_4(view)

      view
      |> form("#deploy-form", instance: %{name: "Bundled"})
      |> render_submit()

      assert_redirect(view)

      [instance] = Instance.list_for_actor!(actor: user)

      # The wizard only ever offered the floors; the row lands on them
      # with the snapshot and none of the platform-owned env keys.
      assert instance.cpu_cores == Decimal.new("1")
      assert instance.memory_mb == 1024
      assert instance.storage_gb == 10
      assert instance.backing_services != []
      assert instance.env_vars["APP_TOKEN"] == "tok"
      refute Map.has_key?(instance.env_vars, "DATABASE_URL")
      refute Map.has_key?(instance.env_vars, "REDIS_URL")
    end
  end

  defp tick_rungs(view, id) do
    view
    |> element("##{id}-ticks")
    |> render()
    |> then(&Regex.scan(~r/data-value="([^"]+)"/, &1))
    |> Enum.map(&Enum.at(&1, 1))
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
