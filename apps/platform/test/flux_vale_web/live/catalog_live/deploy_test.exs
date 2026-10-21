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
    assert has_element?(view, "[data-testid='version-price-#{version.version}']", "$1.00/mo")
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
    assert has_element?(view, "[data-testid='price-summary']", "$1.00/mo")

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
    assert has_element?(view, "[data-testid='resources-price']", "$1.00/mo")
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

      # At the recommendation: no warning, no ack.
      refute has_element?(view, "#below-recommendation-warning")
      assert has_element?(view, "[data-testid='resources-price']", "$1.00/mo")

      to_step_4(view)

      assert has_element?(view, "[data-testid='price-summary']", "$1.00/mo")
    end

    test "an above-recommendation allocation deploys unrestricted, billed at the recommended size meanwhile",
         %{user: user, view: view} do
      stub_k8s()

      view
      |> form("#resources-form",
        resources: %{cpu_cores: "1", memory_mb: "512", storage_gb: "20"}
      )
      |> render_change()

      refute has_element?(view, "#below-recommendation-warning")

      to_step_4(view)

      # Interim pricing note (#180 decision pending): the estimate stays
      # the recommended size's, matching what the ledger charges.
      assert has_element?(view, "[data-testid='price-summary']", "$1.00/mo")
      assert render(view) =~ "billed at the recommended size"

      view
      |> form("#deploy-form", instance: %{name: "Bigger"})
      |> render_submit()

      assert_redirect(view)

      [instance] = Instance.list_for_actor!(actor: user)

      assert instance.cpu_cores == Decimal.new("1")
      assert instance.memory_mb == 512
      assert instance.storage_gb == 20
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
