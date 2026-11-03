defmodule FluxValeWeb.Api.InstanceRouteTest do
  @moduledoc false

  # #360: the instance family's wire contract — list/get as a member,
  # the lifecycle PATCH verbs, and the generic :delete the UI calls.
  # The K8s surface is Mimic-stubbed exactly like the lifecycle suites
  # (Oban testing :inline runs the deploy trigger during the PATCH).

  use FluxValeWeb.ConnCase, async: true
  use Mimic

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
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  # The instance_test suite's own stub set — the deploy trigger's
  # inline run applies the whole namespace.
  defp stub_k8s do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Secret, :create, fn _kc, _ns, _n, _data -> {:ok, %{}} end)
    stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _name, _spec -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
  end

  # The route suite's paid+funded member — the population the lifecycle
  # gates read (welcome credits never qualify, so mark the org paid).
  defp member_with_instance do
    user = elem(ApiPat.member!(), 0)
    BillingFixtures.mark_user_paid!(user)

    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance = InstanceFixtures.instance!(version, user)

    {user, instance}
  end

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  describe "GET /api/v1/instances" do
    test "lists the member's instances with the pinned public field set", %{conn: conn} do
      {user, instance} = member_with_instance()
      pat = ApiPat.mint!(user.email, ["instances:write"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/instances")

      assert %{"data" => [row]} = json_response(conn, 200)
      assert row["type"] == "instance"
      assert row["id"] == instance.id

      # The attribute key set is the contract (the /me stance) — public
      # fields only, no metering anchors, no failure_reason. The raw
      # status_message is #179's admin-only trail and env_vars never
      # rides the wire (hide_fields) — both asserted below.
      keys = Map.keys(row["attributes"])

      assert MapSet.new(keys) ==
               MapSet.new([
                 "name",
                 "slug",
                 "namespace",
                 "status",
                 "exposure",
                 "always_on",
                 "deployed_at"
               ])

      refute Map.has_key?(row["attributes"], "failure_reason")
      refute Map.has_key?(row["attributes"], "running_since")
    end
  end

  describe "GET /api/v1/instances/:id" do
    test "returns the record's public surface", %{conn: conn} do
      {user, instance} = member_with_instance()
      pat = ApiPat.mint!(user.email, ["instances:write"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/instances/#{instance.id}")

      assert %{"data" => row} = json_response(conn, 200)
      assert row["id"] == instance.id
      assert row["attributes"]["name"] == instance.name
      assert row["attributes"]["status"] == "pending"

      # env_vars carries whatever the deployer typed, credentials
      # included — hide_fields keeps it off the wire entirely.
      refute Map.has_key?(row["attributes"], "env_vars")
      refute Map.has_key?(row["attributes"], "status_message")
    end

    test "a sparse fieldset cannot summon the hidden fields", %{conn: conn} do
      {user, instance} = member_with_instance()
      pat = ApiPat.mint!(user.email, ["instances:write"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/instances/#{instance.id}?fields[instance]=name,status_message,env_vars")

      # The hidden pair is off the field catalog entirely — ?fields
      # requests for them are refused as invalid, not silently dropped,
      # so a client can never mistake absence for emptiness.
      assert %{"errors" => errors} = json_response(conn, 400)

      details = Enum.map(errors, & &1["detail"])

      assert "Invalid field for type instance: status_message" in details
      assert "Invalid field for type instance: env_vars" in details
    end
  end

  describe "PATCH /api/v1/instances/:id/deploy" do
    test "enqueues the deploy — the inline trigger lands :starting (K8s stubbed)", %{conn: conn} do
      stub_k8s()
      {user, instance} = member_with_instance()
      pat = ApiPat.mint!(user.email, ["instances:write"])

      deploying =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/instances/#{instance.id}/deploy", %{
          "data" => %{"type" => "instance", "id" => instance.id, "attributes" => %{}}
        })

      # The write's own answer is :deploying with the namespace pinned;
      # the inline trigger races past it (the fixtures' own note) — the
      # fresh read observes :starting.
      assert %{"data" => %{"attributes" => %{"status" => "deploying", "namespace" => ns}}} =
               json_response(deploying, 200)

      assert ns == "fluxvale-app-#{instance.id}"

      fresh =
        build_conn()
        |> auth(pat)
        |> get("/api/v1/instances/#{instance.id}")

      assert %{"data" => %{"attributes" => %{"status" => "starting"}}} =
               json_response(fresh, 200)
    end
  end

  describe "PATCH /api/v1/instances/:id/stop and /start" do
    test "stop scales to zero, start scales back (K8s stubbed)", %{conn: conn} do
      stub_k8s()
      {user, instance} = member_with_instance()
      pat = ApiPat.mint!(user.email, ["instances:write"])

      namespaced = InstanceFixtures.pin!(instance, namespace: "fluxvale-app-#{instance.id}")
      InstanceFixtures.walk_to!(namespaced, :running)

      stopped =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/instances/#{instance.id}/stop", %{
          "data" => %{"type" => "instance", "id" => instance.id, "attributes" => %{}}
        })

      assert %{"data" => %{"attributes" => %{"status" => "stopped"}}} =
               json_response(stopped, 200)

      # A sent conn cannot be reused — a fresh one per request
      # (Phoenix.ConnTest's recycle stance, made explicit).
      restarted =
        build_conn()
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/instances/#{instance.id}/start", %{
          "data" => %{"type" => "instance", "id" => instance.id, "attributes" => %{}}
        })

      assert %{"data" => %{"attributes" => %{"status" => "starting"}}} =
               json_response(restarted, 200)
    end
  end

  describe "PATCH /api/v1/instances/:id/always-on" do
    test "flips the always-on opt-out", %{conn: conn} do
      {user, instance} = member_with_instance()
      pat = ApiPat.mint!(user.email, ["instances:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/instances/#{instance.id}/always-on", %{
          "data" => %{
            "type" => "instance",
            "id" => instance.id,
            "attributes" => %{"always_on" => true}
          }
        })

      assert %{"data" => %{"attributes" => %{"always_on" => true}}} = json_response(conn, 200)
    end
  end

  describe "PATCH /api/v1/instances/:id/exposure" do
    test "toggles exposure — attribute-only on a never-deployed row", %{conn: conn} do
      {user, instance} = member_with_instance()
      pat = ApiPat.mint!(user.email, ["instances:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/instances/#{instance.id}/exposure", %{
          "data" => %{
            "type" => "instance",
            "id" => instance.id,
            "attributes" => %{"exposure" => "private"}
          }
        })

      assert %{"data" => %{"attributes" => %{"exposure" => "private"}}} = json_response(conn, 200)
    end
  end

  describe "DELETE /api/v1/instances/:id" do
    test "hard-deletes a never-deployed row (the UI's generic :delete)", %{conn: conn} do
      {user, instance} = member_with_instance()
      pat = ApiPat.mint!(user.email, ["instances:write"])

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/instances/#{instance.id}")

      # Generic-action routes render the result flat (ash_json_api's
      # own shape) — no JSON:API envelope, the record's public attrs.
      assert body = json_response(conn, 200)
      assert body["id"] == instance.id
      assert body["status"] == "pending"
      refute Map.has_key?(body, "data")

      assert {:error, _not_found} =
               Instance.get_by_id(instance.id,
                 actor: user,
                 authorize?: false
               )
    end
  end
end
