defmodule FluxValeWeb.Api.CatalogRouteTest do
  @moduledoc false

  # #360: the catalog family's wire contract — the browse list, the
  # slug-keyed detail, and the version reads. The read policy is the
  # public-browse one; the /api/v1 pipeline still requires a token.

  # Sync: fabricates app rows with a seeded unique slug (#669).
  use FluxValeWeb.ConnCase, async: false

  import Ecto.Query

  alias FluxVale.Catalog.App
  alias FluxVale.Repo
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

  # #719: icon_url is absolute on the wire — the screenshot precedent
  # at the API edge. The stored and SSR reads keep the relative path so
  # icons stay same-origin (#718).
  describe "icon_url on the wire (#719)" do
    test "the list renders a stored relative path on the canonical origin", %{
      conn: conn,
      pat: pat
    } do
      slug = "icon-list-#{System.unique_integer([:positive])}"
      InstanceFixtures.app_version!(app_slug: slug, icon_url: "/images/catalog/forgejo/icon.svg")

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/apps")

      assert %{"data" => rows} = json_response(conn, 200)
      row = Enum.find(rows, &(&1["attributes"]["slug"] == slug))

      assert row["attributes"]["icon_url"] ==
               "https://fluxvale.com/images/catalog/forgejo/icon.svg"

      # The shaping is the API edge only — the code-interface read the
      # SSR pages ride still returns the stored path.
      assert App.get_by_slug!(slug, authorize?: false).icon_url ==
               "/images/catalog/forgejo/icon.svg"
    end

    test "the detail renders it absolute too", %{conn: conn, pat: pat} do
      slug = "icon-detail-#{System.unique_integer([:positive])}"
      InstanceFixtures.app_version!(app_slug: slug, icon_url: "/images/catalog/forgejo/icon.svg")

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/apps/#{slug}")

      assert %{"data" => row} = json_response(conn, 200)

      assert row["attributes"]["icon_url"] ==
               "https://fluxvale.com/images/catalog/forgejo/icon.svg"
    end

    test "an absent icon_url stays null", %{conn: conn, pat: pat} do
      # The setup's forgejo fixture carries no icon: the designed absent
      # state (#718's contract allows nil).
      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/apps/forgejo")

      assert %{"data" => row} = json_response(conn, 200)
      # The key is present, its value null — not dropped by a
      # default_fields regression.
      assert Map.has_key?(row["attributes"], "icon_url")
      assert row["attributes"]["icon_url"] == nil
    end

    test "a pre-contract absolute icon_url passes through untouched", %{conn: conn, pat: pat} do
      slug = "icon-legacy-#{System.unique_integer([:positive])}"
      %{app_id: app_id} = InstanceFixtures.app_version!(app_slug: slug)

      # Repo.update_all is the seed test's action-bypass — the #718 write
      # contract rejects a hotlink at the action — and plants the legacy
      # shape the lenient read keeps visible.
      plant =
        from(a in App,
          where: a.id == ^app_id,
          update: [set: [icon_url: "https://hotlink.example/legacy.svg"]]
        )

      {1, _result} = Repo.update_all(plant, [])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/apps/#{slug}")

      assert %{"data" => row} = json_response(conn, 200)
      assert row["attributes"]["icon_url"] == "https://hotlink.example/legacy.svg"
    end

    test "the origin is the configured canonical origin", %{conn: conn, pat: pat} do
      # Mutates VM-global config — this module stays async: false.
      slug = "icon-origin-#{System.unique_integer([:positive])}"
      InstanceFixtures.app_version!(app_slug: slug, icon_url: "/images/catalog/forgejo/icon.svg")

      original = Application.get_env(:flux_vale, :canonical_origin)
      on_exit(fn -> Application.put_env(:flux_vale, :canonical_origin, original) end)
      Application.put_env(:flux_vale, :canonical_origin, "https://sentinel.example")

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/apps/#{slug}")

      assert %{"data" => row} = json_response(conn, 200)

      assert row["attributes"]["icon_url"] ==
               "https://sentinel.example/images/catalog/forgejo/icon.svg"
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

    # #700: the route sorts semver-newest-first — the order the
    # Terraform provider's catalog data source inherits. One fixture
    # app, the issue's reproduction set: 10.x above 9.x, the
    # -bundled pre-release below its bare release.
    test "orders versions semver-newest first (#700)", %{conn: conn, pat: pat} do
      app = InstanceFixtures.app_version!(%{version: "3.4.1"})

      for version <- ["3.4.1-bundled", "9.2.0", "10.0.0"] do
        InstanceFixtures.app_version!(%{app_id: app.app_id, version: version})
      end

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/apps/#{app.app_id}/versions")

      assert %{"data" => rows} = json_response(conn, 200)

      assert Enum.map(rows, & &1["attributes"]["version"]) ==
               ["10.0.0", "9.2.0", "3.4.1", "3.4.1-bundled"]
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
