defmodule FluxValeWeb.AdminHealthLiveTest do
  @moduledoc false

  # The Health section (#702): the fleet at a glance through the real
  # mount. The route gates here are the shared live_session's arms
  # (the anonymous 302 and the non-admin 403, pinned once — the
  # people/audit tests' shape). Sync module: one test manipulates the
  # app env for the env chip's absent arm (the capture-and-restore
  # posture; ExUnit runs sync modules alone).

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    InstanceFixtures.local_cluster!()

    admin =
      User.create!("admin-health-live-#{@n}@fluxvale.com", %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin), bare_conn: conn}
  end

  # A fleet instance through actions (the fixture user's funded
  # personal org owns it; the admin reads it through the blanket
  # bypass) plus a fabricated deploy version row — Ash.Seed is the
  # sanctioned bypass: the real :deploy action enqueues k8s/Oban work
  # a test must not run.
  defp fleet_fixtures! do
    version = InstanceFixtures.app_version!(configurable_env_vars: %{})
    member = AccountsFixtures.user!()
    instance = InstanceFixtures.instance!(version, member)

    source = Ecto.UUID.generate()

    Ash.Seed.seed!(FluxVale.Infrastructure.Instance.Version, %{
      version_action_type: :update,
      version_action_name: :deploy,
      version_action_inputs: %{},
      version_source_id: source,
      actor_label: nil,
      version_inserted_at: DateTime.utc_now(),
      changes: %{}
    })

    %{instance: instance, source: source}
  end

  defp text_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  describe "the fleet surface" do
    test "an admin sees the section, the build stamp, the spread, and the deploy trail", %{
      conn: conn
    } do
      %{source: source} = fleet_fixtures!()

      {:ok, view, _html} = live(conn, "/admin/health")

      assert has_element?(view, "[data-testid='admin-health']")
      assert has_element?(view, "[data-testid='admin-health-title']", "Health")

      # The build stamp: the version chip is the /health contract's
      # same value ("dev" in test); the env chip rides config's
      # "local" default.
      assert has_element?(view, "[data-testid='fleet-version']", "Version: dev")
      assert has_element?(view, "[data-testid='fleet-env']")

      # The spread renders the product's own vocabulary (#179): the
      # created instance lands :pending — "Submitted".
      assert has_element?(view, "[data-testid='fleet-status-pending']", "Submitted")

      assert has_element?(view, "[data-testid='fleet-total']")
      assert has_element?(view, "[data-testid='fleet-always-on']")

      # The trail row: the engine's short id, and the nil tombstone's
      # honest System attribution.
      deploys_text = text_of(view, "[data-testid='fleet-deploys']")
      assert deploys_text =~ String.slice(source, 0, 8)
      assert deploys_text =~ "System"

      # The section's sidebar entry is the page; siblings stay quiet.
      assert has_element?(view, "[data-testid='admin-nav-health'][aria-current='page']")
      refute render(element(view, "[data-testid='admin-nav-audit']")) =~ "aria-current"
    end

    test "the env chip renders nothing when the platform has no env", %{conn: conn} do
      # Capture-and-restore (the stub_build_sha posture): config.exs
      # defaults "local", so the nil shape arrives only when unset.
      original = Application.get_env(:flux_vale, :platform_env)
      Application.put_env(:flux_vale, :platform_env, nil)

      on_exit(fn -> Application.put_env(:flux_vale, :platform_env, original) end)

      {:ok, view, _html} = live(conn, "/admin/health")

      refute has_element?(view, "[data-testid='fleet-env']")
      assert has_element?(view, "[data-testid='fleet-version']")
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
