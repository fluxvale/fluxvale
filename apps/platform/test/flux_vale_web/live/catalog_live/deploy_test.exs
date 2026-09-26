defmodule FluxValeWeb.CatalogLive.DeployTest do
  @moduledoc false

  # The deploy stepper (#74): version → env (schema-rendered) → name →
  # create + auto-deploy. K8s is stubbed (Mimic, v1's canonical pattern)
  # because Oban runs inline in tests — the deploy trigger executes
  # synchronously on submit.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

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
    InstanceFixtures.local_cluster!()

    version =
      InstanceFixtures.app_version!(
        configurable_env_vars: @schema,
        default_storage_gb: 10,
        published_at: DateTime.utc_now()
      )

    app = Ash.load!(version, :app, authorize?: false).app
    {:ok, user: user, conn: conn, app: app, version: version}
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

  test "renders the version step", %{conn: conn, app: app, version: version} do
    {:ok, view, html} = live(conn, ~p"/apps/#{app.slug}/deploy")

    assert has_element?(view, "#version-#{version.id}")
    assert has_element?(view, "button[phx-click='to-env']")
    assert html =~ "published"
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

    # From the name step, back returns to env
    view
    |> element("button[phx-click='back-env']")
    |> render_click()

    assert has_element?(view, "#env-form")
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
end
