defmodule FluxValeWeb.Api.PocketIdSsoRoutesTest do
  @moduledoc false

  # #731 T3: the SSO wiring's wire contract — connect (dispatch:
  # pre-deploy vs deployed), disconnect (idempotent), rotate, and the
  # provider's wiring read. Scopes: instances:write for the POSTs,
  # instances:read for the GET. The PocketID operation's external
  # seams are Mimic-stubbed (the operations' own suites pin them).

  # Serialized (async: false) — the shared feature-flag row's
  # lock-order cycles (see connect_pocket_id_test's note).
  use FluxValeWeb.ConnCase, async: false
  use Mimic

  setup :verify_on_exit!

  alias FluxVale.Api.Scopes
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.PocketId.ApiClient
  alias FluxVale.Infrastructure.PocketIdCustody
  alias FluxVale.Infrastructure.PocketIdWiring
  alias FluxVale.Ops.FeatureFlags
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  @held_key "held-key-not-a-real-credential"
  @minted_secret "minted-secret-never-logged"
  @issuer "https://id.example"
  @callback_path "/identity/connect/oidc-signin"

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
    "SSO_ENABLED" => %{label: "Enable Pocket ID sign-in", type: :boolean, default: false},
    "SMTP_HOST" => %{label: "SMTP host", type: :string}
  }

  @wired_env %{
    "SSO_AUTHORITY" => @issuer,
    "SSO_CLIENT_ID" => "client-1",
    "SSO_CLIENT_SECRET" => "old-secret-never-logged",
    "SSO_ENABLED" => "true",
    "SMTP_HOST" => "smtp"
  }

  setup do
    :ok = FeatureFlags.enable(:pocketid_sso_wiring, actor: AccountsFixtures.platform_admin!())

    InstanceFixtures.local_cluster!()

    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    stub(Secret, :get_data, fn _kc, _ns, ref ->
      case ref do
        "fluxvale-pocketid-custody-" <> _suffix -> {:ok, %{"POCKETID_API_KEY" => @held_key}}
        "app-env" -> {:ok, @wired_env}
      end
    end)

    :ok
  end

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  defp json_api(conn), do: put_req_header(conn, "content-type", "application/vnd.api+json")

  # The recipe-carrying app instance + the org's custody-ready
  # PocketID, both owned by `user`.
  defp member_with_pocket_id(user) do
    version =
      InstanceFixtures.app_version!(
        configurable_env_vars: @schema,
        oidc_wiring: @recipe,
        oidc_callback_path: @callback_path
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
      |> InstanceFixtures.pin!(namespace: "ns-pid")

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

  # A deployed instance carrying the wiring's env on the row and a
  # recorded wiring row (the live shape after a connect).
  defp wired_running_app!(user, pocket_id) do
    version =
      InstanceFixtures.app_version!(
        configurable_env_vars: @schema,
        oidc_wiring: @recipe,
        oidc_callback_path: @callback_path
      )

    created =
      Instance.create!(
        %{
          name: "Wired #{System.unique_integer()}",
          app_version_id: version.id,
          env_vars: @wired_env
        },
        actor: user
      )

    app =
      created
      |> InstanceFixtures.walk_to!(:running)
      |> InstanceFixtures.pin!(namespace: "ns-app")

    wiring =
      PocketIdWiring.record!(
        %{
          instance_id: app.id,
          pocket_id_instance_id: pocket_id.id,
          pocket_id_client_id: "client-1",
          pocket_id_secret_id: "secret-1"
        },
        authorize?: false
      )

    {app, wiring}
  end

  defp pocket_id_url(pocket_id) do
    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)
    "https://#{pocket_id.slug}.#{base_domain}"
  end

  defp green_stubs!(pocket_id) do
    url = pocket_id_url(pocket_id)

    stub(ApiClient, :get_discovery, fn ^url -> {:ok, @issuer} end)

    stub(ApiClient, :create_client, fn ^url, @held_key, attrs ->
      {:ok,
       %{client_id: "pid-1", client_name: attrs.name, secret_id: "sec-1", secret: @minted_secret}}
    end)
  end

  describe "POST /api/v1/instances/:id/connect-pocketid — the dispatch" do
    test "a pending instance rides the pre-deploy call — env on the row, no cluster apply",
         %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      {app, pocket_id} = member_with_pocket_id(user)
      green_stubs!(pocket_id)
      pat = ApiPat.mint!(user, ["instances:write"])

      conn =
        conn
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{app.id}/connect-pocketid", %{
          "data" => %{"pocket_id_instance_id" => pocket_id.id}
        })

      # The flat generic-action body: the wiring row, ids only.
      assert body = json_response(conn, 201)
      assert body["instance_id"] == app.id
      assert body["pocket_id_instance_id"] == pocket_id.id
      assert body["pocket_id_client_id"] == "pid-1"
      assert body["pocket_id_secret_id"] == "sec-1"
      assert is_binary(body["wired_at"])

      # The row is the durable record; no Secret/Deployment stub is
      # armed, so Mimic proves the cluster was never touched.
      reloaded = Instance.get_by_id!(app.id, actor: user)
      assert reloaded.env_vars["SSO_AUTHORITY"] == @issuer
      assert reloaded.env_vars["SSO_CLIENT_SECRET"] == @minted_secret
      assert {:ok, _wiring} = PocketIdWiring.get_by_instance(app.id, authorize?: false)
    end

    test "a running instance rides the retrofit — row + live workload", %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      {pending_app, pocket_id} = member_with_pocket_id(user)
      green_stubs!(pocket_id)

      app =
        pending_app
        |> InstanceFixtures.walk_to!(:running)
        |> InstanceFixtures.pin!(namespace: "ns-retro")

      expect(Secret, :upsert, fn _kc, "ns-retro", "app-env", data ->
        send(self(), {:applied, data})
        {:ok, %{}}
      end)

      expect(Deployment, :restart, fn _kc, "ns-retro", "app", opts ->
        assert opts[:ensure_env_from] == "app-env"
        {:ok, %{}}
      end)

      pat = ApiPat.mint!(user, ["instances:write"])

      conn =
        conn
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{app.id}/connect-pocketid", %{
          "data" => %{"pocket_id_instance_id" => pocket_id.id}
        })

      assert body = json_response(conn, 201)
      assert body["pocket_id_client_id"] == "pid-1"
      refute Jason.encode!(body) =~ @minted_secret

      assert_received {:applied, applied}
      assert applied["SSO_AUTHORITY"] == @issuer
      assert applied["SSO_CLIENT_ID"] == "pid-1"
      assert applied["SSO_CLIENT_SECRET"] == @minted_secret

      reloaded = Instance.get_by_id!(app.id, actor: user)
      assert reloaded.env_vars["SSO_CLIENT_SECRET"] == @minted_secret
    end

    test "a mid-rollout app refuses busy — the T1 stance", %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      {pending_app, pocket_id} = member_with_pocket_id(user)

      app = InstanceFixtures.walk_to!(pending_app, :deploying)
      pat = ApiPat.mint!(user, ["instances:write"])

      conn =
        conn
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{app.id}/connect-pocketid", %{
          "data" => %{"pocket_id_instance_id" => pocket_id.id}
        })

      # The in-flight rollout owns the workload; dispatch answers before
      # an operation could race it (no discovery/mint stub is armed).
      assert [%{"detail" => detail} | _rest] = json_response(conn, 400)["errors"]
      assert detail =~ "busy"
      assert detail =~ "deploying"
      assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, authorize?: false)
    end
  end

  describe "POST /api/v1/instances/:id/disconnect-pocketid" do
    test "the first disconnect deletes, strips row + workload, clears; the second is idempotent",
         %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      {_unwired_app, pocket_id} = member_with_pocket_id(user)
      {app, _wiring} = wired_running_app!(user, pocket_id)
      pat = ApiPat.mint!(user, ["instances:write"])

      expect(ApiClient, :delete_client, fn _url, @held_key, "client-1" -> :ok end)

      expect(Secret, :upsert, fn _kc, "ns-app", "app-env", data ->
        send(self(), {:stripped, data})
        {:ok, %{}}
      end)

      expect(Deployment, :restart, fn _kc, "ns-app", "app", _opts -> {:ok, %{}} end)

      conn =
        conn
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{app.id}/disconnect-pocketid")

      assert body = json_response(conn, 201)
      assert body == %{"instance_id" => app.id, "client_deleted" => true}

      assert_received {:stripped, stripped}
      assert stripped == %{"SMTP_HOST" => "smtp"}
      assert Instance.get_by_id!(app.id, actor: user).env_vars == %{"SMTP_HOST" => "smtp"}
      assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, authorize?: false)

      # Second call: nothing wired — a success with client_deleted
      # false, and NO cluster calls (the expects above are spent).
      second =
        build_conn()
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{app.id}/disconnect-pocketid")

      assert second_body = json_response(second, 201)
      assert second_body == %{"instance_id" => app.id, "client_deleted" => false}
    end

    test "a refused client delete still disconnects — client_deleted is false", %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      {_unwired_app, pocket_id} = member_with_pocket_id(user)
      {app, _wiring} = wired_running_app!(user, pocket_id)

      stub(ApiClient, :delete_client, fn _url, _key, _client -> {:error, :unreachable} end)
      stub(Secret, :upsert, fn _kc, _ns, _name, _data -> {:ok, %{}} end)
      stub(Deployment, :restart, fn _kc, _ns, _name, _opts -> {:ok, %{}} end)

      pat = ApiPat.mint!(user, ["instances:write"])

      conn =
        conn
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{app.id}/disconnect-pocketid")

      # The leftover client stays visible in PocketID's admin (D6);
      # the platform side converged.
      assert body = json_response(conn, 201)
      assert body == %{"instance_id" => app.id, "client_deleted" => false}
      assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, authorize?: false)
    end

    test "a vanished live Secret refuses with redeploy-to-repair copy", %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      {_unwired_app, pocket_id} = member_with_pocket_id(user)
      {app, _wiring} = wired_running_app!(user, pocket_id)

      stub(ApiClient, :delete_client, fn _url, _key, _client -> :ok end)

      stub(Secret, :get_data, fn _kc, _ns, ref ->
        case ref do
          "fluxvale-pocketid-custody-" <> _suffix ->
            {:ok, %{"POCKETID_API_KEY" => @held_key}}

          "app-env" ->
            {:error, %K8s.Error{status_code: 404, reason: :not_found, message: "absent"}}
        end
      end)

      # A managed status must NOT skip the cluster leg; the missing
      # Secret is the honest refusal (nothing half-lands).
      reject(Secret, :upsert, 4)
      reject(Deployment, :restart, 4)

      pat = ApiPat.mint!(user, ["instances:write"])

      conn =
        conn
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{app.id}/disconnect-pocketid")

      assert [%{"detail" => detail} | _rest] = json_response(conn, 400)["errors"]
      assert detail =~ "live environment is gone"
      assert detail =~ "redeploy"

      # The wiring stands until the platform side actually lands.
      assert {:ok, _stands} = PocketIdWiring.get_by_instance(app.id, authorize?: false)
    end
  end

  describe "POST /api/v1/instances/:id/rotate-pocketid-secret" do
    test "rotates: the wiring row comes back with the new secret id, the workload saw it",
         %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      {_unwired_app, pocket_id} = member_with_pocket_id(user)
      {app, wiring} = wired_running_app!(user, pocket_id)
      url = pocket_id_url(pocket_id)

      stub(ApiClient, :create_secret, fn ^url, @held_key, "client-1", new_secret ->
        send(self(), {:minted, new_secret})
        {:ok, %{secret_id: "secret-new"}}
      end)

      expect(ApiClient, :delete_secret, fn ^url, @held_key, "client-1", "secret-1" -> :ok end)

      expect(Secret, :upsert, fn _kc, "ns-app", "app-env", data ->
        send(self(), {:applied, data})
        {:ok, %{}}
      end)

      expect(Deployment, :restart, fn _kc, "ns-app", "app", _opts -> {:ok, %{}} end)

      pat = ApiPat.mint!(user, ["instances:write"])

      conn =
        conn
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{app.id}/rotate-pocketid-secret")

      # The flat generic-action body: the wiring row, the new secret id
      # — never the secret value.
      assert body = json_response(conn, 201)
      assert body["instance_id"] == app.id
      assert body["pocket_id_client_id"] == "client-1"
      assert body["pocket_id_secret_id"] == "secret-new"
      assert is_binary(body["wired_at"])

      assert_received {:minted, new_secret}
      assert byte_size(new_secret) >= 16
      refute Jason.encode!(body) =~ new_secret

      assert_received {:applied, applied}
      assert applied["SSO_CLIENT_SECRET"] == new_secret
      assert applied["SMTP_HOST"] == "smtp"

      assert PocketIdWiring.get_by_instance!(app.id, authorize?: false).id == wiring.id

      assert PocketIdWiring.get_by_instance!(app.id, authorize?: false).pocket_id_secret_id ==
               "secret-new"
    end

    test "no wiring is an honest refusal — nothing is invented", %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      {pending_app, _pocket_id} = member_with_pocket_id(user)

      app =
        pending_app
        |> InstanceFixtures.walk_to!(:running)
        |> InstanceFixtures.pin!(namespace: "ns-nowire")

      pat = ApiPat.mint!(user, ["instances:write"])

      conn =
        conn
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{app.id}/rotate-pocketid-secret")

      assert [%{"detail" => detail} | _rest] = json_response(conn, 400)["errors"]
      assert detail =~ "no Pocket ID sign-in wiring"
      assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, authorize?: false)
    end

    test "a not-yet-deployed wiring refuses honestly — nothing to roll", %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      {app, pocket_id} = member_with_pocket_id(user)

      PocketIdWiring.record!(
        %{
          instance_id: app.id,
          pocket_id_instance_id: pocket_id.id,
          pocket_id_client_id: "client-1",
          pocket_id_secret_id: "secret-1"
        },
        authorize?: false
      )

      pat = ApiPat.mint!(user, ["instances:write"])

      conn =
        conn
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{app.id}/rotate-pocketid-secret")

      assert [%{"detail" => detail} | _rest] = json_response(conn, 400)["errors"]
      assert detail =~ "not deployed right now"

      assert PocketIdWiring.get_by_instance!(app.id, authorize?: false).pocket_id_secret_id ==
               "secret-1"
    end
  end

  describe "GET /api/v1/instances/:instance_id/pocket-id-wiring" do
    test "wired: 200 with exactly the default fields", %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      {app, pocket_id} = member_with_pocket_id(user)

      wiring =
        PocketIdWiring.record!(
          %{
            instance_id: app.id,
            pocket_id_instance_id: pocket_id.id,
            pocket_id_client_id: "client-1",
            pocket_id_secret_id: "secret-1"
          },
          authorize?: false
        )

      pat = ApiPat.mint!(user, ["instances:read"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/instances/#{app.id}/pocket-id-wiring")

      assert body = json_response(conn, 200)
      assert body["data"]["type"] == "pocket_id_wiring"
      assert body["data"]["id"] == wiring.id

      assert body["data"]["attributes"] == %{
               "instance_id" => app.id,
               "pocket_id_instance_id" => pocket_id.id,
               "pocket_id_client_id" => "client-1",
               "pocket_id_secret_id" => "secret-1",
               "wired_at" => DateTime.to_iso8601(wiring.wired_at)
             }
    end

    test "unwired: 404", %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      {app, _pocket_id} = member_with_pocket_id(user)
      pat = ApiPat.mint!(user, ["instances:read"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/instances/#{app.id}/pocket-id-wiring")

      assert %{"errors" => [%{"status" => "404"} | _rest]} = json_response(conn, 404)
    end

    test "a non-member sees 404 — the read policy's own posture", %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      {app, pocket_id} = member_with_pocket_id(user)

      PocketIdWiring.record!(
        %{
          instance_id: app.id,
          pocket_id_instance_id: pocket_id.id,
          pocket_id_client_id: "client-1",
          pocket_id_secret_id: "secret-1"
        },
        authorize?: false
      )

      {_other_org, stranger} = BillingFixtures.grant_free_org!()
      pat = ApiPat.mint!(stranger, ["instances:read"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/instances/#{app.id}/pocket-id-wiring")

      assert %{"errors" => [%{"code" => "not_found"} | _rest]} = json_response(conn, 404)
    end
  end

  describe "scopes" do
    test "a non-member's disconnect and rotate are NotFound (the authorized get inside)", %{
      conn: conn
    } do
      user = elem(ApiPat.member!(), 0)
      {_unwired_app, pocket_id} = member_with_pocket_id(user)
      {app, _wiring} = wired_running_app!(user, pocket_id)

      {_other_org, stranger} = BillingFixtures.grant_free_org!()
      pat = ApiPat.mint!(stranger, ["instances:write"])

      disconnect =
        conn
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{app.id}/disconnect-pocketid")

      # The authorized get_by_id filters strangers to not-found —
      # indistinguishable from an unknown id (the read policy's own
      # posture).
      assert [%{"code" => "not_found"} | _rest] = json_response(disconnect, 404)["errors"]

      rotate =
        build_conn()
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{app.id}/rotate-pocketid-secret")

      assert [%{"code" => "not_found"} | _rest] = json_response(rotate, 404)["errors"]
    end

    test "the boundary names instances:write for the POSTs and instances:read for the GET" do
      id = Ash.UUID.generate()

      assert Scopes.required_scope("POST", ["instances", id, "disconnect-pocketid"]) ==
               {:ok, "instances:write"}

      assert Scopes.required_scope("POST", ["instances", id, "rotate-pocketid-secret"]) ==
               {:ok, "instances:write"}

      assert Scopes.required_scope("GET", ["instances", id, "pocket-id-wiring"]) ==
               {:ok, "instances:read"}
    end

    test "a read-only token is refused on all three POSTs", %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      {_unwired_app, pocket_id} = member_with_pocket_id(user)
      {app, _wiring} = wired_running_app!(user, pocket_id)
      pat = ApiPat.mint!(user, ["instances:read"])

      connect =
        conn
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{app.id}/connect-pocketid", %{
          "data" => %{"pocket_id_instance_id" => pocket_id.id}
        })

      assert json_response(connect, 403)

      disconnect =
        build_conn()
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{app.id}/disconnect-pocketid")

      assert json_response(disconnect, 403)

      rotate =
        build_conn()
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{app.id}/rotate-pocketid-secret")

      assert json_response(rotate, 403)
    end

    test "a token without instances:read is refused on the wiring GET", %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      {app, _pocket_id} = member_with_pocket_id(user)
      pat = ApiPat.mint!(user, ["backups:read"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/instances/#{app.id}/pocket-id-wiring")

      assert json_response(conn, 403)
    end
  end

  describe "the race-window refusal copy" do
    test "the inverse race names the status and the retry" do
      assert %Ash.Error.Changes.InvalidArgument{message: message} =
               Instance.wiring_error({:instance_not_deployed, :pending})

      assert message ==
               "this app is not deployed right now (pending) — retry once it settles"
    end

    test "the busy refusal names the status" do
      assert %Ash.Error.Changes.InvalidArgument{message: message} =
               Instance.wiring_error({:instance_busy, :restoring})

      assert message == "this app is busy (restoring) — retry when it settles"
    end
  end

  describe "flag-off" do
    test "connect, disconnect, and rotate surface the honest copy", %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      {app, pocket_id} = member_with_pocket_id(user)
      {wired_app, _wiring} = wired_running_app!(user, pocket_id)

      :ok = FeatureFlags.disable(:pocketid_sso_wiring, actor: AccountsFixtures.platform_admin!())
      pat = ApiPat.mint!(user, ["instances:write"])

      connect =
        conn
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{app.id}/connect-pocketid", %{
          "data" => %{"pocket_id_instance_id" => pocket_id.id}
        })

      assert [%{"detail" => connect_detail} | _rest] = json_response(connect, 400)["errors"]
      assert connect_detail =~ "turned off"

      disconnect =
        build_conn()
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{wired_app.id}/disconnect-pocketid")

      assert [%{"detail" => disconnect_detail} | _rest] =
               json_response(disconnect, 400)["errors"]

      assert disconnect_detail =~ "turned off"

      rotate =
        build_conn()
        |> auth(pat)
        |> json_api()
        |> post("/api/v1/instances/#{wired_app.id}/rotate-pocketid-secret")

      assert [%{"detail" => rotate_detail} | _rest] = json_response(rotate, 400)["errors"]
      assert rotate_detail =~ "turned off"
    end

    test "the wiring read stays available while the mutations are off", %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      {app, pocket_id} = member_with_pocket_id(user)

      wiring =
        PocketIdWiring.record!(
          %{
            instance_id: app.id,
            pocket_id_instance_id: pocket_id.id,
            pocket_id_client_id: "client-1",
            pocket_id_secret_id: "secret-1"
          },
          authorize?: false
        )

      :ok = FeatureFlags.disable(:pocketid_sso_wiring, actor: AccountsFixtures.platform_admin!())
      pat = ApiPat.mint!(user, ["instances:read"])

      # A provider refresh must not lose state during a shutdown window
      # — the flag gates the mutations only.
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/instances/#{app.id}/pocket-id-wiring")

      assert body = json_response(conn, 200)
      assert body["data"]["id"] == wiring.id
      assert body["data"]["attributes"]["pocket_id_secret_id"] == "secret-1"
    end
  end
end
