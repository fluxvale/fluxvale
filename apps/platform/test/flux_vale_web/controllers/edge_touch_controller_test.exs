defmodule FluxValeWeb.EdgeTouchControllerTest do
  @moduledoc false

  # The beacon contract (#203): always 204, never a failure to the
  # forwarded request; probes never move the clock; marks are debounced.

  # async: false — marks go through the app's named Activity
  # GenServer; its writes must see this test's sandbox (shared mode).
  use FluxValeWeb.ConnCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias FluxVale.Edge.Activity
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Repo
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    Sandbox.allow(Repo, self(), Process.whereis(Activity))

    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(
        %{name: "App", app_version_id: version.id, env_vars: %{}},
        actor:
          User.create!("touch-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
      )

    {:ok, instance: instance}
  end

  test "a real visitor's request marks the idle clock", %{conn: conn, instance: instance} do
    conn =
      conn
      |> put_req_header("user-agent", "Mozilla/5.0 (X11; Linux x86_64)")
      |> get("/internal/edge/touch?instance=#{instance.id}")

    assert response(conn, 204)

    touched = Instance.get_by_id!(instance.id, authorize?: false)
    assert touched.last_used_at
  end

  test "a probe's request never marks — the settled must-NOT-count rule", %{
    conn: conn,
    instance: instance
  } do
    conn =
      conn
      |> put_req_header("user-agent", "kube-probe/1.29")
      |> get("/internal/edge/touch?instance=#{instance.id}")

    assert response(conn, 204)

    untouched = Instance.get_by_id!(instance.id, authorize?: false)
    refute untouched.last_used_at
  end

  test "a missing instance param still 204s — the beacon must not 500 an app", %{conn: conn} do
    conn = get(conn, "/internal/edge/touch")
    assert response(conn, 204)
  end

  test "a stale instance id still 204s", %{conn: conn} do
    ghost = "00000000-0000-7000-8000-000000000000"

    conn = get(conn, "/internal/edge/touch?instance=#{ghost}")
    assert response(conn, 204)
  end
end
