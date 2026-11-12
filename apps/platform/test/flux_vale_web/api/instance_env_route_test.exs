defmodule FluxValeWeb.Api.InstanceEnvRouteTest do
  @moduledoc false

  # #731 T1 (ADR-0052): PATCH /api/v1/instances/:id/env — the merge
  # verb's wire contract: member-gated, instances:write, the standard
  # instance document back, and honest 400s. Values are write-only.

  use FluxValeWeb.ConnCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  setup :verify_on_exit!

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  @sentinel "route-sentinel-value-never-echoed"

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  defp patch_env(conn, pat, instance, attributes) do
    conn
    |> auth(pat)
    |> put_req_header("content-type", "application/vnd.api+json")
    |> patch("/api/v1/instances/#{instance.id}/env", %{
      "data" => %{
        "type" => "instance",
        "id" => instance.id,
        "attributes" => attributes
      }
    })
  end

  defp member_instance!(opts \\ []) do
    InstanceFixtures.local_cluster!()
    user = elem(ApiPat.member!(), 0)
    BillingFixtures.mark_user_paid!(user)
    version = Keyword.get_lazy(opts, :version, fn -> InstanceFixtures.app_version!() end)
    created = InstanceFixtures.instance!(version, user)

    advanced =
      case Keyword.fetch(opts, :status) do
        {:ok, status} -> InstanceFixtures.walk_to!(created, status)
        :error -> created
      end

    instance =
      if Keyword.get(opts, :pin, false) do
        InstanceFixtures.pin!(advanced, namespace: "ns-live")
      else
        advanced
      end

    {user, instance}
  end

  defp detail(conn, status) do
    assert [%{"detail" => detail} | _rest] = json_response(conn, status)["errors"]
    detail
  end

  test "200: the standard instance document, env never echoed", %{conn: conn} do
    {user, instance} = member_instance!()
    pat = ApiPat.mint!(user, ["instances:write"])

    conn =
      patch_env(conn, pat, instance, %{
        "set" => %{"API_KEY" => @sentinel},
        "remove" => []
      })

    assert %{"data" => row} = json_response(conn, 200)
    assert row["type"] == "instance"
    assert row["id"] == instance.id

    assert row["attributes"]["status"] == "pending"
    refute Map.has_key?(row["attributes"], "env_vars")
    refute conn.resp_body =~ @sentinel

    # The row is the truth; the response is the detail projection.
    reloaded = Instance.get_by_id!(instance.id, authorize?: false)
    assert reloaded.env_vars == %{"API_KEY" => @sentinel}
  end

  test "200: a running row also upserts the Secret and restarts (K8s stubbed)", %{conn: conn} do
    {user, instance} = member_instance!(status: :running, pin: true)
    pat = ApiPat.mint!(user, ["instances:write"])

    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)
    stub(Secret, :get_data, fn _kc, _ns, "app-env" -> {:ok, %{}} end)
    stub(Secret, :upsert, fn _kc, _ns, "app-env", _data -> {:ok, %{}} end)
    stub(Deployment, :restart, fn _kc, _ns, "app", _opts -> {:ok, %{}} end)

    conn = patch_env(conn, pat, instance, %{"set" => %{"NEW" => "2"}, "remove" => nil})

    assert %{"data" => row} = json_response(conn, 200)
    assert row["attributes"]["status"] == "running"
    assert Instance.get_by_id!(instance.id, authorize?: false).env_vars == %{"NEW" => "2"}
  end

  test "400: invalid names and values", %{conn: conn} do
    {user, instance} = member_instance!()
    pat = ApiPat.mint!(user, ["instances:write"])

    bad_name_conn = patch_env(conn, pat, instance, %{"set" => %{"BAD-KEY" => "v"}})
    assert detail(bad_name_conn, 400) =~ "POSIX-shaped"

    bad_value_conn = patch_env(build_conn(), pat, instance, %{"set" => %{"NUMBER" => 1}})
    assert detail(bad_value_conn, 400) =~ "must be strings"
  end

  test "400: set/remove overlap", %{conn: conn} do
    {user, instance} = member_instance!()
    pat = ApiPat.mint!(user, ["instances:write"])

    conn =
      patch_env(conn, pat, instance, %{"set" => %{"A" => "1"}, "remove" => ["A"]})

    assert detail(conn, 400) =~ "both set and removed"
  end

  test "400: a platform-owned key names itself", %{conn: conn} do
    version = InstanceFixtures.app_version!(instance_url_env: "ROOT_URL")
    {user, instance} = member_instance!(version: version)
    pat = ApiPat.mint!(user, ["instances:write"])

    conn = patch_env(conn, pat, instance, %{"set" => %{"ROOT_URL" => "https://evil"}})

    assert detail(conn, 400) =~ "managed by the platform"
    assert detail(conn, 400) =~ "ROOT_URL"
  end

  test "400: busy and deleting statuses", %{conn: conn} do
    {user, deploying} = member_instance!(status: :deploying)
    pat = ApiPat.mint!(user, ["instances:write"])

    conn = patch_env(conn, pat, deploying, %{"set" => %{"A" => "1"}})
    assert detail(conn, 400) =~ "busy (deploying)"

    deleting =
      deploying
      |> Ash.Changeset.for_update(:update_status, %{status: :deleting}, authorize?: false)
      |> Ash.update!()

    deleting_conn = patch_env(build_conn(), pat, deleting, %{"set" => %{"A" => "1"}})
    assert detail(deleting_conn, 400) =~ "being deleted"
  end

  test "400: a refused restart answers with the post-commit copy", %{conn: conn} do
    {user, instance} = member_instance!(status: :running, pin: true)
    pat = ApiPat.mint!(user, ["instances:write"])

    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)
    stub(Secret, :get_data, fn _kc, _ns, "app-env" -> {:ok, %{}} end)
    stub(Secret, :upsert, fn _kc, _ns, "app-env", _data -> {:ok, %{}} end)

    stub(Deployment, :restart, fn _kc, _ns, "app", _opts ->
      {:error, %K8s.Error{status_code: 500, reason: :unknown, message: "roll refused"}}
    end)

    conn = patch_env(conn, pat, instance, %{"set" => %{"NEW" => "2"}})

    assert detail(conn, 400) =~
             "the environment was saved, but the rolling restart was refused — retry"
  end

  # The house wire posture: a non-member's row is 404 — the read
  # policy filters it out before the update policy can answer
  # Forbidden (the resource-layer test pins the 403). AshJsonApi's
  # PATCH fetch runs the primary read action, and a filter-shaped
  # membership check cannot yield a distinguishable 403 without
  # exposing the row.
  test "a non-member's row is 404 — the read policy filters", %{conn: conn} do
    {_owner, instance} = member_instance!()
    {_other_org, stranger} = BillingFixtures.grant_free_org!()
    pat = ApiPat.mint!(stranger, ["instances:write"])

    conn = patch_env(conn, pat, instance, %{"set" => %{"A" => "1"}})

    assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)
  end

  test "403: a read-only token is refused by the scope gate", %{conn: conn} do
    {user, instance} = member_instance!()
    pat = ApiPat.mint!(user, ["instances:read"])

    conn = patch_env(conn, pat, instance, %{"set" => %{"A" => "1"}})

    assert %{"errors" => [error]} = json_response(conn, 403)
    assert error["detail"] == "token is missing the required scope instances:write"
  end

  test "the route is instances:write — a write token succeeds", %{conn: conn} do
    {user, instance} = member_instance!()
    pat = ApiPat.mint!(user, ["instances:write"])

    conn = patch_env(conn, pat, instance, %{"set" => %{"A" => "1"}})

    assert json_response(conn, 200)
  end

  test "the sentinel never reaches the response, logs, or the PaperTrail version", %{conn: conn} do
    {user, instance} = member_instance!()
    pat = ApiPat.mint!(user, ["instances:write"])

    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    {conn, log} =
      with_log([], fn ->
        patch_env(conn, pat, instance, %{"set" => %{"API_KEY" => @sentinel}})
      end)

    assert json_response(conn, 200)
    refute conn.resp_body =~ @sentinel
    refute log =~ @sentinel

    version =
      Instance.Version
      |> Ash.Query.filter(version_source_id == ^instance.id)
      |> Ash.Query.sort(version_inserted_at: :asc)
      |> Ash.read!(authorize?: false)
      |> List.last()

    assert version.version_action_name == :update_env
    refute inspect(version.changes) =~ @sentinel
    refute inspect(version.version_action_inputs) =~ @sentinel
  end
end
