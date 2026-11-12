defmodule FluxValeWeb.Api.InstanceSlugRouteTest do
  @moduledoc false

  # #731 T2: GET /api/v1/instances/by-slug/:slug — the Terraform data
  # source's lookup. Slug is unique only per [:slug, :cluster_id], so
  # the optional organization_id scopes a multi-cluster caller; a slug
  # that still matches more than one visible row refuses honestly
  # (Ash's MultipleResults — never an arbitrary pick). The membership
  # read policy filters the result (a non-member sees 404).

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  # The detail set every instance-document route answers with (@detail_fields).
  @detail_keys MapSet.new([
                 "name",
                 "slug",
                 "namespace",
                 "status",
                 "exposure",
                 "always_on",
                 "image",
                 "port",
                 "healthcheck_path",
                 "storage_mount_path",
                 "file_access",
                 "cpu_cores",
                 "memory_mb",
                 "storage_gb",
                 "deployed_at"
               ])

  @duplicate_slug "dup-slug"

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  defp get_by_slug(conn, pat, slug, params \\ []) do
    conn
    |> auth(pat)
    |> get("/api/v1/instances/by-slug/#{slug}", params)
  end

  defp member_instance! do
    user = elem(ApiPat.member!(), 0)
    BillingFixtures.mark_user_paid!(user)
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()
    instance = InstanceFixtures.instance!(version, user)
    {user, instance}
  end

  # Two visible rows, same slug, different clusters AND orgs: the bare
  # slug is ambiguous; an org scopes each row. The second cluster only
  # appears after both creates (ResolveCluster refuses multiple).
  defp ambiguous_pair! do
    user = elem(ApiPat.member!(), 0)
    org_a = AccountsFixtures.personal_org!(user)
    BillingFixtures.funded_wallet!(org: org_a)
    org_b = AccountsFixtures.owned_org!(user)
    BillingFixtures.funded_wallet!(org: org_b)

    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    created_a =
      Instance.create!(%{name: "Dup A", app_version_id: version.id}, actor: user)

    created_b =
      Instance.create!(
        %{name: "Dup B", app_version_id: version.id, organization_id: org_b.id},
        actor: user
      )

    cluster_b = InstanceFixtures.local_cluster!()

    instance_a = InstanceFixtures.pin!(created_a, slug: @duplicate_slug)

    instance_b =
      InstanceFixtures.pin!(created_b, slug: @duplicate_slug, cluster_id: cluster_b.id)

    {user, org_a, org_b, instance_a, instance_b}
  end

  test "200: the detail document by slug", %{conn: conn} do
    {user, instance} = member_instance!()
    pat = ApiPat.mint!(user, ["instances:read"])

    conn = get_by_slug(conn, pat, instance.slug)

    assert %{"data" => row} = json_response(conn, 200)
    assert row["type"] == "instance"
    assert row["id"] == instance.id
    assert row["attributes"]["slug"] == instance.slug
    assert row["attributes"]["name"] == instance.name
    assert row["attributes"]["status"] == "pending"
    keys = Map.keys(row["attributes"])
    assert MapSet.new(keys) == @detail_keys

    refute Map.has_key?(row["attributes"], "env_vars")
    refute Map.has_key?(row["attributes"], "status_message")
  end

  test "200: organization_id scopes the lookup to the right row", %{conn: conn} do
    {user, instance} = member_instance!()
    org = AccountsFixtures.personal_org!(user)
    {foreign_org, _owner} = BillingFixtures.grant_free_org!()
    pat = ApiPat.mint!(user, ["instances:read"])

    assert %{"data" => %{"id" => id}} =
             conn
             |> get_by_slug(pat, instance.slug, organization_id: org.id)
             |> json_response(200)

    assert id == instance.id

    # The argument filters: another org's id resolves nothing.
    foreign_conn =
      get_by_slug(build_conn(), pat, instance.slug, organization_id: foreign_org.id)

    assert %{"errors" => [%{"status" => "404"}]} = json_response(foreign_conn, 404)
  end

  test "404: an unknown slug", %{conn: conn} do
    {user, _instance} = member_instance!()
    pat = ApiPat.mint!(user, ["instances:read"])

    conn = get_by_slug(conn, pat, "no-such-slug")

    assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)
  end

  test "404: a non-member's instance — the read policy filters", %{conn: conn} do
    {_owner, instance} = member_instance!()
    {_foreign_org, stranger} = BillingFixtures.grant_free_org!()
    pat = ApiPat.mint!(stranger, ["instances:read"])

    conn = get_by_slug(conn, pat, instance.slug)

    assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)
  end

  test "403: a token without instances:read is refused by the scope gate", %{conn: conn} do
    {user, instance} = member_instance!()
    pat = ApiPat.mint!(user, ["catalog:read"])

    conn = get_by_slug(conn, pat, instance.slug)

    assert %{"errors" => [error]} = json_response(conn, 403)
    assert error["detail"] == "token is missing the required scope instances:read"
  end

  test "a slug that matches more than one visible row refuses — never an arbitrary pick" do
    {user, _org_a, _org_b, _instance_a, _instance_b} = ambiguous_pair!()
    pat = ApiPat.mint!(user, ["instances:read"])

    conn = get_by_slug(build_conn(), pat, @duplicate_slug)

    # Ash's `get?` refuses MultipleResults (the log carries the honest
    # error); FluxVale.Api.JsonApiErrors names it on the wire.
    assert %{"errors" => [error]} = json_response(conn, 400)
    assert error["status"] == "400"
    assert error["code"] == "multiple_results"
    assert error["title"] == "Multiple results"

    assert error["detail"] ==
             "more than one record matches this query — narrow the filter; " <>
               "for an instance slug lookup, pass organization_id or use the instance id"
  end

  test "200: slug + organization_id resolves one row even when the bare slug is ambiguous" do
    {user, org_a, org_b, instance_a, instance_b} = ambiguous_pair!()
    pat = ApiPat.mint!(user, ["instances:read"])

    assert %{"data" => %{"id" => id_a}} =
             build_conn()
             |> get_by_slug(pat, @duplicate_slug, organization_id: org_a.id)
             |> json_response(200)

    assert id_a == instance_a.id

    assert %{"data" => %{"id" => id_b}} =
             build_conn()
             |> get_by_slug(pat, @duplicate_slug, organization_id: org_b.id)
             |> json_response(200)

    assert id_b == instance_b.id
  end
end
