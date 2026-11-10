defmodule FluxValeWeb.Api.ConnectPocketIdRouteTest do
  @moduledoc false

  # #597 S4: the wiring verb's wire contract — POST
  # /api/v1/instances/:id/connect-pocketid, instances:write-scoped,
  # member-gated (the authorized get_by_id inside the action), the
  # PocketID operation beneath with Mimic stubs. The response carries
  # the wiring row's identifiers; every refusal is honest words.

  # Serialized (async: false) — the shared feature-flag row's
  # lock-order cycles (see connect_pocket_id_test's note).
  use FluxValeWeb.ConnCase, async: false
  use Mimic

  setup :verify_on_exit!

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.PocketId.ApiClient
  alias FluxVale.Infrastructure.PocketIdCustody
  alias FluxVale.Ops.FeatureFlags
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  @held_key "held-key-not-a-real-credential"
  @minted_secret "minted-secret-never-logged"
  @issuer "https://id.example"

  @recipe %{
    "kind" => "env",
    "issuer_env" => "SSO_AUTHORITY",
    "client_id_env" => "SSO_CLIENT_ID",
    "client_secret_env" => "SSO_CLIENT_SECRET",
    "enabled_env" => "SSO_ENABLED",
    "pkce" => true
  }

  @schema %{
    "SSO_AUTHORITY" => %{label: "OIDC issuer URL", type: :string},
    "SSO_CLIENT_ID" => %{label: "OIDC client ID", type: :string},
    "SSO_CLIENT_SECRET" => %{label: "OIDC client secret", type: :string, secret: true},
    "SSO_ENABLED" => %{label: "Enable Pocket ID sign-in", type: :boolean, default: false}
  }

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  setup do
    :ok = FeatureFlags.enable(:pocketid_sso_wiring, actor: AccountsFixtures.platform_admin!())

    InstanceFixtures.local_cluster!()

    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    stub(Secret, :get_data, fn _kc, _ns, _ref ->
      {:ok, %{"POCKETID_API_KEY" => @held_key}}
    end)

    :ok
  end

  # The pending, recipe-carrying app instance + the org's active,
  # custody-ready PocketID, both owned by `user`.
  defp member_with_pocket_id(user) do
    version =
      InstanceFixtures.app_version!(
        configurable_env_vars: @schema,
        oidc_wiring: @recipe,
        oidc_callback_path: "/identity/connect/oidc-signin"
      )

    app = InstanceFixtures.instance!(version, user)

    pocket_id_version =
      InstanceFixtures.app_version!(
        app_slug: "pocket-id-#{System.unique_integer()}",
        configurable_env_vars: %{}
      )

    pocket_id =
      pocket_id_version
      |> InstanceFixtures.instance!(user)
      |> InstanceFixtures.walk_to!(:running)
      |> InstanceFixtures.pin!(namespace: "ns")

    PocketIdCustody.record!(
      %{
        organization_id: pocket_id.organization_id,
        instance_id: pocket_id.id,
        api_key_secret_ref: "fluxvale-pocketid-custody-#{pocket_id.id}",
        verified_at: DateTime.utc_now()
      },
      authorize?: false
    )

    {app, pocket_id}
  end

  defp green_stubs!(pocket_id) do
    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)
    url = "https://#{pocket_id.slug}.#{base_domain}"

    stub(ApiClient, :get_discovery, fn ^url -> {:ok, @issuer} end)

    stub(ApiClient, :create_client, fn ^url, @held_key, attrs ->
      {:ok,
       %{client_id: "pid-1", client_name: attrs.name, secret_id: "sec-1", secret: @minted_secret}}
    end)
  end

  test "wires a pending instance — 201 with the wiring row, ids only", %{conn: conn} do
    user = elem(ApiPat.member!(), 0)
    {app, pocket_id} = member_with_pocket_id(user)
    green_stubs!(pocket_id)
    pat = ApiPat.mint!(user, ["instances:write"])

    conn =
      conn
      |> auth(pat)
      |> put_req_header("content-type", "application/vnd.api+json")
      |> post("/api/v1/instances/#{app.id}/connect-pocketid", %{
        "data" => %{"pocket_id_instance_id" => pocket_id.id}
      })

    # Generic-action shape: flat, the row's public attributes —
    # identifiers only, never the secret (that lives in env).
    assert body = json_response(conn, 201)
    assert body["instance_id"] == app.id
    assert body["pocket_id_instance_id"] == pocket_id.id
    assert body["pocket_id_client_id"] == "pid-1"
    assert body["pocket_id_secret_id"] == "sec-1"
    assert is_binary(body["wired_at"])
    refute Jason.encode!(body) =~ @minted_secret

    # The env shipped on the row for the next deploy.
    reloaded = Instance.get_by_id!(app.id, actor: user)
    assert reloaded.env_vars["SSO_AUTHORITY"] == @issuer
    assert reloaded.env_vars["SSO_CLIENT_SECRET"] == @minted_secret
  end

  test "a deployed instance refuses honestly — the S5 posture, by name", %{conn: conn} do
    user = elem(ApiPat.member!(), 0)
    {app, pocket_id} = member_with_pocket_id(user)
    green_stubs!(pocket_id)

    InstanceFixtures.walk_to!(app, :running)

    pat = ApiPat.mint!(user, ["instances:write"])

    conn =
      conn
      |> auth(pat)
      |> put_req_header("content-type", "application/vnd.api+json")
      |> post("/api/v1/instances/#{app.id}/connect-pocketid", %{
        "data" => %{"pocket_id_instance_id" => pocket_id.id}
      })

    assert [%{"detail" => detail} | _rest] = json_response(conn, 400)["errors"]
    assert detail =~ "already deployed"
    assert detail =~ "instance page"
  end

  test "a deleting instance refuses honestly — nothing to wire", %{conn: conn} do
    user = elem(ApiPat.member!(), 0)
    {app, pocket_id} = member_with_pocket_id(user)
    green_stubs!(pocket_id)

    # The funnel's deleting entry (the teardown trigger's own write —
    # walk_to! has no :deleting leg, and StatusTransition would refuse
    # a shortcut anyway).
    app
    |> Ash.Changeset.for_update(:update_status, %{status: :deleting}, authorize?: false)
    |> Ash.update!()

    pat = ApiPat.mint!(user, ["instances:write"])

    conn =
      conn
      |> auth(pat)
      |> put_req_header("content-type", "application/vnd.api+json")
      |> post("/api/v1/instances/#{app.id}/connect-pocketid", %{
        "data" => %{"pocket_id_instance_id" => pocket_id.id}
      })

    assert [%{"detail" => detail} | _rest] = json_response(conn, 400)["errors"]
    assert detail =~ "being deleted"
  end

  # The refused mint's raw status map: the wire answer carries the
  # status (the body snippet stays in the ApiClient's logs).
  test "a refused mint answers with the status in honest words", %{conn: conn} do
    user = elem(ApiPat.member!(), 0)
    {app, pocket_id} = member_with_pocket_id(user)

    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)
    url = "https://#{pocket_id.slug}.#{base_domain}"

    stub(ApiClient, :get_discovery, fn ^url -> {:ok, @issuer} end)

    stub(ApiClient, :create_client, fn ^url, @held_key, _attrs ->
      {:error, %{status: 400, body: "nope"}}
    end)

    pat = ApiPat.mint!(user, ["instances:write"])

    conn =
      conn
      |> auth(pat)
      |> put_req_header("content-type", "application/vnd.api+json")
      |> post("/api/v1/instances/#{app.id}/connect-pocketid", %{
        "data" => %{"pocket_id_instance_id" => pocket_id.id}
      })

    assert [%{"detail" => detail} | _rest] = json_response(conn, 400)["errors"]
    assert detail =~ "refused the client"
    assert detail =~ "400"
    # D3: the instance stays deployable, env untouched, no row.
    reloaded = Instance.get_by_id!(app.id, actor: user)
    assert reloaded.status == :pending
    refute Map.has_key?(reloaded.env_vars, "SSO_AUTHORITY")
  end

  test "the fail-closed flag refuses even with everything else ready", %{conn: conn} do
    user = elem(ApiPat.member!(), 0)
    {app, pocket_id} = member_with_pocket_id(user)

    :ok = FeatureFlags.disable(:pocketid_sso_wiring, actor: AccountsFixtures.platform_admin!())

    pat = ApiPat.mint!(user, ["instances:write"])

    conn =
      conn
      |> auth(pat)
      |> put_req_header("content-type", "application/vnd.api+json")
      |> post("/api/v1/instances/#{app.id}/connect-pocketid", %{
        "data" => %{"pocket_id_instance_id" => pocket_id.id}
      })

    assert [%{"detail" => detail} | _rest] = json_response(conn, 400)["errors"]
    assert detail =~ "turned off"
  end

  # The key read's cluster-outage shape: use_pocket_id_key passes the
  # K8s client's error struct verbatim — honest words on the wire,
  # and D3's posture holds (instance untouched, deployable).
  test "a cluster outage at the key read answers in honest words", %{conn: conn} do
    user = elem(ApiPat.member!(), 0)
    {app, pocket_id} = member_with_pocket_id(user)

    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)
    url = "https://#{pocket_id.slug}.#{base_domain}"

    stub(ApiClient, :get_discovery, fn ^url -> {:ok, @issuer} end)

    stub(Secret, :get_data, fn _kc, _ns, _ref ->
      {:error, %FluxVale.Clients.K8s.Error{status_code: 500, reason: :unknown, message: "boom"}}
    end)

    pat = ApiPat.mint!(user, ["instances:write"])

    conn =
      conn
      |> auth(pat)
      |> put_req_header("content-type", "application/vnd.api+json")
      |> post("/api/v1/instances/#{app.id}/connect-pocketid", %{
        "data" => %{"pocket_id_instance_id" => pocket_id.id}
      })

    assert [%{"detail" => detail} | _rest] = json_response(conn, 400)["errors"]
    assert detail =~ "could not be read from the cluster"

    reloaded = Instance.get_by_id!(app.id, actor: user)
    assert reloaded.status == :pending
    refute Map.has_key?(reloaded.env_vars, "SSO_AUTHORITY")
  end

  # A 2xx mint with no createdSecret (CodeRabbit): the instance's
  # client-secret settings — honest words, not a raw atom.
  test "a mint answering with no secret gets honest words", %{conn: conn} do
    user = elem(ApiPat.member!(), 0)
    {app, pocket_id} = member_with_pocket_id(user)

    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)
    url = "https://#{pocket_id.slug}.#{base_domain}"

    stub(ApiClient, :get_discovery, fn ^url -> {:ok, @issuer} end)

    stub(ApiClient, :create_client, fn ^url, @held_key, _attrs -> {:error, :no_created_secret} end)

    pat = ApiPat.mint!(user, ["instances:write"])

    conn =
      conn
      |> auth(pat)
      |> put_req_header("content-type", "application/vnd.api+json")
      |> post("/api/v1/instances/#{app.id}/connect-pocketid", %{
        "data" => %{"pocket_id_instance_id" => pocket_id.id}
      })

    assert [%{"detail" => detail} | _rest] = json_response(conn, 400)["errors"]
    assert detail =~ "returned no secret"
    assert reloaded = Instance.get_by_id!(app.id, actor: user)
    assert reloaded.status == :pending
  end

  test "a PocketID from another org is refused honestly", %{conn: conn} do
    user = elem(ApiPat.member!(), 0)
    {app, _own_pocket_id} = member_with_pocket_id(user)

    {other_org, stranger} = BillingFixtures.grant_free_org!()
    BillingFixtures.funded_wallet!(org: other_org)

    pocket_id_version =
      InstanceFixtures.app_version!(
        app_slug: "pocket-id-#{System.unique_integer()}",
        configurable_env_vars: %{}
      )

    foreign =
      pocket_id_version
      |> InstanceFixtures.instance!(stranger)
      |> InstanceFixtures.walk_to!(:running)
      |> InstanceFixtures.pin!(namespace: "ns")

    pat = ApiPat.mint!(user, ["instances:write"])

    conn =
      conn
      |> auth(pat)
      |> put_req_header("content-type", "application/vnd.api+json")
      |> post("/api/v1/instances/#{app.id}/connect-pocketid", %{
        "data" => %{"pocket_id_instance_id" => foreign.id}
      })

    assert [%{"detail" => detail} | _rest] = json_response(conn, 400)["errors"]
    assert detail =~ "another organization"
  end

  test "a non-member's read is NotFound (the membership filter's stance)", %{conn: conn} do
    user = elem(ApiPat.member!(), 0)
    {app, pocket_id} = member_with_pocket_id(user)
    green_stubs!(pocket_id)

    {_other_org, stranger} = BillingFixtures.grant_free_org!()
    pat = ApiPat.mint!(stranger, ["instances:write"])

    conn =
      conn
      |> auth(pat)
      |> put_req_header("content-type", "application/vnd.api+json")
      |> post("/api/v1/instances/#{app.id}/connect-pocketid", %{
        "data" => %{"pocket_id_instance_id" => pocket_id.id}
      })

    # The authorized get_by_id inside the action filters strangers to
    # not-found — indistinguishable from an unknown id (the read
    # policy's own posture).
    assert [%{"code" => "not_found"} | _rest] = json_response(conn, 404)["errors"]
  end

  test "the route demands instances:write", %{conn: conn} do
    user = elem(ApiPat.member!(), 0)
    {app, pocket_id} = member_with_pocket_id(user)
    green_stubs!(pocket_id)

    # read-only scope: the boundary denies before the action runs.
    pat = ApiPat.mint!(user, ["instances:read"])

    conn =
      conn
      |> auth(pat)
      |> put_req_header("content-type", "application/vnd.api+json")
      |> post("/api/v1/instances/#{app.id}/connect-pocketid", %{
        "data" => %{"pocket_id_instance_id" => pocket_id.id}
      })

    assert json_response(conn, 403)
  end
end
