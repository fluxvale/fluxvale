defmodule FluxValeWeb.Api.StorageRequestRouteTest do
  @moduledoc """
  #250's member wire contract: the instance's request create/list (path
  `:instance_id`, never a body attribute), the single read, the member
  field surface (advisory quote and decision fields; no operator
  internals), org scoping, and the instances:read/write scope gate.
  Operator decisions have no route — no admin scope exists.
  """

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.Infrastructure.StorageRequest
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.StorageRequestFixtures

  @member_fields [
    "applied_at",
    "current_storage_gb",
    "decided_at",
    "instance_id",
    "organization_id",
    "quoted_current_cents",
    "quoted_monthly_cents",
    "reason",
    "rejection_reason",
    "requested_by_user_id",
    "requested_gb",
    "status"
  ]

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  defp member_with_instance do
    {user, pat} = ApiPat.member!(["instances:write", "instances:read"])

    version = InstanceFixtures.app_version!(default_storage_gb: 10)
    InstanceFixtures.local_cluster!()
    instance = InstanceFixtures.instance!(version, user)

    {user, pat, instance}
  end

  defp request!(instance, user, attrs \\ %{}) do
    StorageRequestFixtures.request!(instance, user, attrs)
  end

  defp reject!(request) do
    admin = AccountsFixtures.platform_admin!()
    {:ok, rejected} = StorageRequest.reject(request, %{rejection_reason: "No"}, actor: admin)
    rejected
  end

  describe "POST /api/v1/instances/:instance_id/storage-requests" do
    test "creates a requested row with instance_id from the PATH", %{conn: conn} do
      {_user, pat, instance} = member_with_instance()

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/storage-requests", %{
          "data" => %{
            "type" => "storage_request",
            "attributes" => %{"requested_gb" => 150, "reason" => "Need room for archives"}
          }
        })

      assert %{"data" => row} = json_response(conn, 201)
      assert row["type"] == "storage_request"
      assert row["attributes"]["instance_id"] == instance.id
      assert row["attributes"]["requested_gb"] == 150
      assert row["attributes"]["current_storage_gb"] == instance.storage_gb
      assert row["attributes"]["reason"] == "Need room for archives"
      assert row["attributes"]["status"] == "requested"
      assert is_integer(row["attributes"]["quoted_monthly_cents"])
      assert is_integer(row["attributes"]["quoted_current_cents"])
    end

    test "the member surface carries no operator internals", %{conn: conn} do
      {_user, pat, instance} = member_with_instance()

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/storage-requests", %{
          "data" => %{
            "type" => "storage_request",
            "attributes" => %{"requested_gb" => 150, "reason" => "Need room"}
          }
        })

      assert %{"data" => row} = json_response(conn, 201)

      keys = Map.keys(row["attributes"])
      assert MapSet.new(keys) == MapSet.new(@member_fields)
      refute Map.has_key?(row["attributes"], "apply_error")
      refute Map.has_key?(row["attributes"], "decided_by_user_id")
    end

    test "instance_id is the path's alone — a body copy is refused", %{conn: conn} do
      {_user, pat, instance} = member_with_instance()

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/storage-requests", %{
          "data" => %{
            "type" => "storage_request",
            "attributes" => %{
              "instance_id" => instance.id,
              "requested_gb" => 150,
              "reason" => "Need room"
            }
          }
        })

      assert %{"errors" => [%{"code" => "invalid_body"}]} = json_response(conn, 400)
    end

    test "a within-boundary target is refused with the server's copy", %{conn: conn} do
      {_user, pat, instance} = member_with_instance()

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/storage-requests", %{
          "data" => %{
            "type" => "storage_request",
            "attributes" => %{"requested_gb" => 100, "reason" => "Boundary"}
          }
        })

      assert %{"errors" => [error]} = json_response(conn, 400)
      assert error["detail"] =~ "self-service storage covers up to 100 GB"
    end

    test "another org's instance is refused and writes no row", %{conn: conn} do
      {_owner, _owner_pat, instance} = member_with_instance()
      {_stranger, stranger_pat} = ApiPat.member!(["instances:write"])

      conn =
        conn
        |> auth(stranger_pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/storage-requests", %{
          "data" => %{
            "type" => "storage_request",
            "attributes" => %{"requested_gb" => 150, "reason" => "Not mine"}
          }
        })

      assert %{"errors" => [_error]} = json_response(conn, 400)
      assert Ash.read!(StorageRequest, authorize?: false) == []
    end

    test "a read-only token cannot create", %{conn: conn} do
      {_user, _pat, instance} = member_with_instance()
      {_reader, read_pat} = ApiPat.member!(["instances:read"])

      conn =
        conn
        |> auth(read_pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/storage-requests", %{
          "data" => %{
            "type" => "storage_request",
            "attributes" => %{"requested_gb" => 150, "reason" => "Need room"}
          }
        })

      assert %{"errors" => [error]} = json_response(conn, 403)
      assert error["detail"] =~ "scope"
    end
  end

  describe "GET /api/v1/instances/:instance_id/storage-requests" do
    test "lists the instance's requests newest first", %{conn: conn} do
      {user, pat, instance} = member_with_instance()

      older = request!(instance, user, %{requested_gb: 150})
      rejected = reject!(older)
      newest = request!(instance, user, %{requested_gb: 200})

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/instances/#{instance.id}/storage-requests")

      assert %{"data" => rows} = json_response(conn, 200)
      assert Enum.map(rows, & &1["id"]) == [newest.id, rejected.id]
      assert Enum.all?(rows, &(&1["attributes"]["instance_id"] == instance.id))
    end

    test "another org's instance lists an empty set", %{conn: conn} do
      {owner, _owner_pat, instance} = member_with_instance()
      request!(instance, owner)
      {_stranger, stranger_pat} = ApiPat.member!(["instances:read"])

      conn =
        conn
        |> auth(stranger_pat)
        |> get("/api/v1/instances/#{instance.id}/storage-requests")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "a non-instances token is refused", %{conn: conn} do
      {_user, _pat, instance} = member_with_instance()
      {_reader, backup_pat} = ApiPat.member!(["backups:read"])

      conn =
        conn
        |> auth(backup_pat)
        |> get("/api/v1/instances/#{instance.id}/storage-requests")

      assert %{"errors" => [_error]} = json_response(conn, 403)
    end
  end

  describe "GET /api/v1/storage-requests/:id" do
    test "returns the member's request", %{conn: conn} do
      {user, pat, instance} = member_with_instance()
      request = request!(instance, user)

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/storage-requests/#{request.id}")

      assert %{"data" => row} = json_response(conn, 200)
      assert row["id"] == request.id
      assert row["type"] == "storage_request"
      assert row["attributes"]["requested_gb"] == 150
    end

    test "another org's request is not found", %{conn: conn} do
      {owner, _owner_pat, instance} = member_with_instance()
      request = request!(instance, owner)
      {_stranger, stranger_pat} = ApiPat.member!(["instances:read"])

      conn =
        conn
        |> auth(stranger_pat)
        |> get("/api/v1/storage-requests/#{request.id}")

      assert %{"errors" => [_error]} = json_response(conn, 404)
    end
  end
end
