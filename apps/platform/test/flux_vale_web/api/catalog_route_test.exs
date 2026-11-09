defmodule FluxValeWeb.Api.CatalogRouteTest do
  @moduledoc false

  # #360: the catalog family's wire contract — the browse list, the
  # slug-keyed detail, and the version reads. The read policy is the
  # public-browse one; the /api/v1 pipeline still requires a token.

  # Sync: fabricates app rows with seeded slugs ("forgejo",
  # "vaultwarden"), which are globally unique and shared with other
  # modules doing the same. Sync modules run alone, so the race cannot
  # form (#669).
  use FluxValeWeb.ConnCase, async: false

  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.InstanceFixtures

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  setup do
    version = InstanceFixtures.app_version!(app_slug: "forgejo")
    pat = elem(ApiPat.member!(["catalog:read"]), 1)
    %{version: version, pat: pat}
  end

  describe "GET /api/v1/apps" do
    test "lists the catalog sorted by name", %{conn: conn, pat: pat} do
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/apps")

      assert %{"data" => rows} = json_response(conn, 200)
      assert [%{"type" => "app"} | _rest] = rows

      names = Enum.map(rows, & &1["attributes"]["name"])
      assert names == Enum.sort(names)

      row = Enum.find(rows, &(&1["attributes"]["slug"] == "forgejo"))
      assert row["attributes"]["file_access"] == false
    end
  end

  describe "GET /api/v1/apps/:slug" do
    test "returns the app by slug", %{conn: conn, version: version, pat: pat} do
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/apps/forgejo")

      assert %{"data" => row} = json_response(conn, 200)
      assert row["type"] == "app"
      assert row["id"] == version.app_id
      assert row["attributes"]["slug"] == "forgejo"
      assert row["attributes"]["name"]
    end

    test "an unknown slug is a 404", %{conn: conn, pat: pat} do
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/apps/no-such-app")

      assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)
    end
  end

  describe "GET /api/v1/apps/:app_id/versions" do
    test "lists the app's versions newest first", %{conn: conn, version: version, pat: pat} do
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/apps/#{version.app_id}/versions")

      assert %{"data" => [row]} = json_response(conn, 200)
      assert row["type"] == "app_version"
      assert row["id"] == version.id
      assert row["attributes"]["image"] == "registry.example.com/app:1.0"
      assert row["attributes"]["port"] == 3000
    end
  end

  describe "GET /api/v1/app-versions/:id" do
    test "returns the version by id", %{conn: conn, version: version, pat: pat} do
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/app-versions/#{version.id}")

      assert %{"data" => row} = json_response(conn, 200)
      assert row["id"] == version.id
      assert row["attributes"]["version"] == version.version
      assert row["attributes"]["default_memory_mb"] == 256
    end
  end

  # #362 regression: fixtures shipped empty spec lists, so only empty-spec
  # versions ever encoded — the seeded Forgejo's real specs (and first_run
  # contract) 500'd both reads with "Jason.Encoder not implemented for
  # EnvVarSpec". The fixture carries that crash shape, shaped from the
  # seed YAML (a subset: two of its six specs, guidance shortened).
  describe "version reads — populated env specs (#362)" do
    setup do
      forgejo_version =
        InstanceFixtures.app_version!(
          configurable_env_vars: %{
            "FORGEJO__mailer__SMTP_PORT" => %{
              label: "SMTP port",
              description: "Port of the SMTP server.",
              type: "integer",
              default: 587
            },
            "FORGEJO__mailer__PASSWD" => %{label: "SMTP password", type: "string", secret: true}
          },
          first_run: %{
            "pattern" => "first_registered_user_admin",
            "env" => %{"FORGEJO__security__INSTALL_LOCK" => "true"},
            "forbidden_env" => ["FORGEJO__service__DISABLE_REGISTRATION"],
            "guidance" =>
              "Open the instance URL and register — the first account becomes the admin."
          }
        )

      pat = elem(ApiPat.member!(["catalog:read"]), 1)
      %{forgejo_version: forgejo_version, pat: pat}
    end

    test "the versions list renders env specs as plain maps", %{
      conn: conn,
      forgejo_version: version,
      pat: pat
    } do
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/apps/#{version.app_id}/versions")

      assert %{"data" => [row]} = json_response(conn, 200)

      assert row["attributes"]["configurable_env_vars"]["FORGEJO__mailer__SMTP_PORT"] == %{
               "label" => "SMTP port",
               "description" => "Port of the SMTP server.",
               "type" => "integer",
               "default" => 587,
               "required" => false,
               "secret" => false
             }

      assert row["attributes"]["configurable_env_vars"]["FORGEJO__mailer__PASSWD"]["secret"] ==
               true
    end

    test "the app-version get renders the contract fields too", %{
      conn: conn,
      forgejo_version: version,
      pat: pat
    } do
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/app-versions/#{version.id}")

      assert %{"data" => row} = json_response(conn, 200)

      assert row["attributes"]["configurable_env_vars"]["FORGEJO__mailer__SMTP_PORT"]["type"] ==
               "integer"

      assert row["attributes"]["first_run"] == %{
               "pattern" => "first_registered_user_admin",
               "env" => %{"FORGEJO__security__INSTALL_LOCK" => "true"},
               "forbidden_env" => ["FORGEJO__service__DISABLE_REGISTRATION"],
               "guidance" =>
                 "Open the instance URL and register — the first account becomes the admin."
             }
    end
  end

  # #597: the wiring recipe is catalog data a client can read (names
  # only, the oidc_callback_path stance) — the fixture mirrors the
  # Vaultwarden seed's recipe over its own declared SSO_* inputs.
  describe "version reads — oidc_wiring (#597)" do
    setup do
      wired_version =
        InstanceFixtures.app_version!(
          app_slug: "vaultwarden",
          configurable_env_vars: %{
            "SSO_AUTHORITY" => %{label: "OIDC issuer URL", type: "string"},
            "SSO_CLIENT_ID" => %{label: "OIDC client ID", type: "string"},
            "SSO_CLIENT_SECRET" => %{label: "OIDC client secret", type: "string", secret: true},
            "SSO_ENABLED" => %{label: "Enable Pocket ID sign-in", type: "boolean", default: false}
          },
          oidc_wiring: %{
            "kind" => "env",
            "issuer_env" => "SSO_AUTHORITY",
            "client_id_env" => "SSO_CLIENT_ID",
            "client_secret_env" => "SSO_CLIENT_SECRET",
            "enabled_env" => "SSO_ENABLED",
            "pkce" => true
          }
        )

      pat = elem(ApiPat.member!(["catalog:read"]), 1)
      %{wired_version: wired_version, pat: pat}
    end

    test "the versions list renders the recipe as the storage shape", %{
      conn: conn,
      wired_version: version,
      pat: pat
    } do
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/apps/#{version.app_id}/versions")

      assert %{"data" => [row]} = json_response(conn, 200)

      assert row["attributes"]["oidc_wiring"] == %{
               "kind" => "env",
               "issuer_env" => "SSO_AUTHORITY",
               "client_id_env" => "SSO_CLIENT_ID",
               "client_secret_env" => "SSO_CLIENT_SECRET",
               "enabled_env" => "SSO_ENABLED",
               "pkce" => true
             }
    end

    test "the app-version get renders it too", %{conn: conn, wired_version: version, pat: pat} do
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/app-versions/#{version.id}")

      assert %{"data" => row} = json_response(conn, 200)
      assert row["attributes"]["oidc_wiring"]["client_secret_env"] == "SSO_CLIENT_SECRET"
      assert row["attributes"]["oidc_wiring"]["pkce"] == true
    end

    test "a recipe-less version renders null, not an error", %{conn: conn, pat: pat} do
      plain = InstanceFixtures.app_version!()

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/app-versions/#{plain.id}")

      assert %{"data" => row} = json_response(conn, 200)
      assert row["attributes"]["oidc_wiring"] == nil
    end
  end

  # #612 (ADR-0045): the bundled-services declaration is catalog data a
  # client can read — names only (kind, major, url_env), never values
  # (the oidc_callback_path stance: no values exist at catalog level).
  describe "version reads — backing_services (#612)" do
    setup do
      registry = Application.fetch_env!(:flux_vale, :backing_services)

      pg_entries = Keyword.fetch!(registry, :postgres)
      redis_entries = Keyword.fetch!(registry, :redis)
      pg_major = hd(Map.keys(pg_entries))
      redis_major = hd(Map.keys(redis_entries))

      db_version =
        InstanceFixtures.app_version!(
          configurable_env_vars: %{
            "DATABASE_URL" => %{label: "Database URL", type: "string", secret: true},
            "REDIS_URL" => %{label: "Redis URL", type: "string", secret: true}
          },
          backing_services: [
            %{"kind" => "postgres", "version" => pg_major, "url_env" => "DATABASE_URL"},
            %{"kind" => "redis", "version" => redis_major, "url_env" => "REDIS_URL"}
          ]
        )

      pat = elem(ApiPat.member!(["catalog:read"]), 1)
      %{db_version: db_version, pg_major: pg_major, redis_major: redis_major, pat: pat}
    end

    test "the versions list renders the pair as the storage shape", %{
      conn: conn,
      db_version: version,
      pg_major: pg_major,
      redis_major: redis_major,
      pat: pat
    } do
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/apps/#{version.app_id}/versions")

      assert %{"data" => [row]} = json_response(conn, 200)

      assert row["attributes"]["backing_services"] == [
               %{"kind" => "postgres", "version" => pg_major, "url_env" => "DATABASE_URL"},
               %{"kind" => "redis", "version" => redis_major, "url_env" => "REDIS_URL"}
             ]
    end

    test "the app-version get renders it too", %{
      conn: conn,
      db_version: version,
      redis_major: redis_major,
      pat: pat
    } do
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/app-versions/#{version.id}")

      assert %{"data" => row} = json_response(conn, 200)

      assert [_postgres, %{"kind" => "redis", "version" => ^redis_major}] =
               row["attributes"]["backing_services"]
    end

    test "a services-less version renders an empty list, not an error", %{conn: conn, pat: pat} do
      plain = InstanceFixtures.app_version!()

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/app-versions/#{plain.id}")

      assert %{"data" => row} = json_response(conn, 200)
      assert row["attributes"]["backing_services"] == []
    end
  end
end
