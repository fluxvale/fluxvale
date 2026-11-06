defmodule FluxValeWeb.Api.BackupRouteTest do
  @moduledoc false

  # #360: the backups family's wire contract — settings CRUD keyed by
  # the path's instance id, the run history, and the panel's run/
  # restore verbs (the K8s stubs the operation suites use). The
  # paywall proofs (policy 403s) live in paywall_route_test.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.BackupJob
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RestoreJob
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  # A paid+funded member with a deployed instance — the runnable
  # population (the operation's own wallet gate reads the ledger).
  defp member_with_instance do
    user = elem(ApiPat.member!(), 0)
    BillingFixtures.mark_user_paid!(user)

    version = InstanceFixtures.app_version!(default_storage_gb: 10)
    InstanceFixtures.local_cluster!()

    instance = InstanceFixtures.instance!(version, user)

    deployed =
      instance
      |> InstanceFixtures.pin!(namespace: "fluxvale-app-#{instance.id}")
      |> InstanceFixtures.walk_to!(:running)

    {user, deployed}
  end

  defp setting!(instance) do
    BackupSetting
    |> Ash.Changeset.for_create(
      :create,
      %{
        instance_id: instance.id,
        endpoint: "https://account.r2.cloudflarestorage.com",
        bucket: "fluxvale-kavita",
        prefix: "fluxvale/app",
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        retention_keep: 7
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  # The restore op test's own two-write shape: create then finalize.
  defp run!(instance, attrs) do
    base = %{
      instance_id: instance.id,
      kind: :scheduled,
      status: :succeeded,
      started_at: DateTime.utc_now()
    }

    attrs = Map.merge(base, Map.new(attrs))
    {outcome, creatable} = Map.split(attrs, [:snapshot_id, :bytes_added, :error_summary])

    run =
      BackupRun
      |> Ash.Changeset.for_create(:create, creatable, authorize?: false)
      |> Ash.create!()

    case outcome do
      empty when empty == %{} ->
        run

      finalize ->
        run
        |> Ash.Changeset.for_update(:update, finalize, authorize?: false)
        |> Ash.update!()
    end
  end

  defp stub_backup_cluster do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
    stub(BackupJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
  end

  # The restore suite's happy-path cluster (its own stub set).
  defp stub_restore_cluster do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)

    stub(Deployment, :get, fn _kc, _ns, "app" ->
      {:ok, %{"metadata" => %{"name" => "app"}, "status" => %{"replicas" => 0}}}
    end)

    stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
    stub(RestoreJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
    stub(RestoreJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
  end

  describe "GET /api/v1/instances/:instance_id/backup-setting" do
    test "404s unconfigured, returns the row once configured", %{conn: conn} do
      {user, instance} = member_with_instance()
      pat = ApiPat.mint!(user.email, ["backups:write"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/instances/#{instance.id}/backup-setting")

      assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)

      setting = setting!(instance)

      fresh =
        build_conn()
        |> auth(pat)
        |> get("/api/v1/instances/#{instance.id}/backup-setting")

      assert %{"data" => row} = json_response(fresh, 200)
      assert row["type"] == "backup_setting"
      assert row["id"] == setting.id
      assert row["attributes"]["bucket"] == "fluxvale-kavita"
      assert row["attributes"]["retention_keep"] == 7
      assert row["attributes"]["enabled"] == true
    end
  end

  describe "POST /api/v1/instances/:instance_id/backup-setting" do
    test "creates the row with instance_id from the PATH", %{conn: conn} do
      {user, instance} = member_with_instance()
      pat = ApiPat.mint!(user.email, ["backups:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/backup-setting", %{
          "data" => %{
            "type" => "backup_setting",
            "attributes" => %{
              "endpoint" => "https://account.r2.cloudflarestorage.com",
              "bucket" => "fluxvale-kavita",
              "prefix" => "fluxvale/app",
              "access_key_id" => "AKIAIOSFODNN7EXAMPLE",
              "retention_keep" => 14
            }
          }
        })

      assert %{"data" => row} = json_response(conn, 201)
      assert row["attributes"]["instance_id"] == instance.id
      assert row["attributes"]["retention_keep"] == 14
    end

    test "instance_id is the path's alone — a body copy is refused, not merged", %{conn: conn} do
      {user, instance} = member_with_instance()

      other_version = InstanceFixtures.app_version!()
      other = InstanceFixtures.instance!(other_version, user)

      pat = ApiPat.mint!(user.email, ["backups:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/backup-setting", %{
          "data" => %{
            "type" => "backup_setting",
            "attributes" => %{
              "instance_id" => other.id,
              "endpoint" => "https://account.r2.cloudflarestorage.com",
              "bucket" => "fluxvale-kavita",
              "access_key_id" => "AKIAIOSFODNN7EXAMPLE"
            }
          }
        })

      # ash_json_api's own body schema refuses the key outright — the
      # path is the one intake for instance_id, by construction.
      assert %{"errors" => [%{"code" => "invalid_body"}]} = json_response(conn, 400)
    end
  end

  # #482: the write-only secret_access_key argument — the provider's
  # credential intake. The K8s stubs mirror the operation suite's
  # (get_data not_found → fresh Secret with a generated password;
  # get_data {:ok, stored} → the stored password survives, the key
  # rotates). Absent/blank keeps the Secret untouched, so those saves
  # make ZERO cluster calls — proven with rejects.
  describe "the write-only secret_access_key argument" do
    test "POST with a secret (re)applies the namespace Secret — the operation's one path", %{
      conn: conn
    } do
      {user, instance} = member_with_instance()
      pat = ApiPat.mint!(user.email, ["backups:write"])

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      expect(Secret, :get_data, fn _kc, ns, "backup-config" ->
        assert ns == "fluxvale-app-#{instance.id}"
        {:error, %Error{reason: :not_found}}
      end)

      expect(Secret, :create, fn _kc, _ns, "backup-config", data ->
        assert data["AWS_SECRET_ACCESS_KEY"] == "provider-secret-value"
        assert data["AWS_ACCESS_KEY_ID"] == "AKIAIOSFODNN7EXAMPLE"

        # Fresh repo password, generated once (the operation's recipe).
        assert Regex.match?(~r/^[A-Za-z0-9_-]{43}$/, data["RESTIC_PASSWORD"])

        {:ok, %{}}
      end)

      # The routes apply the Secret only — the quota stays the
      # operation's full-save concern.
      reject(ResourceQuota, :create, 4)

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/backup-setting", %{
          "data" => %{
            "type" => "backup_setting",
            "attributes" => %{
              "endpoint" => "https://account.r2.cloudflarestorage.com",
              "bucket" => "fluxvale-kavita",
              "access_key_id" => "AKIAIOSFODNN7EXAMPLE",
              "secret_access_key" => "provider-secret-value"
            }
          }
        })

      assert %{"data" => row} = json_response(conn, 201)
      assert row["attributes"]["access_key_id"] == "AKIAIOSFODNN7EXAMPLE"

      # Write-only: the argument never renders, under any key.
      refute Map.has_key?(row["attributes"], "secret_access_key")

      # And the GET surface stays closed too.
      fresh =
        build_conn()
        |> auth(pat)
        |> get("/api/v1/instances/#{instance.id}/backup-setting")

      assert %{"data" => %{"attributes" => attrs}} = json_response(fresh, 200)
      refute Map.has_key?(attrs, "secret_access_key")

      assert {:ok, _row} = BackupSetting.get_by_instance(instance.id, actor: user)
    end

    test "PATCH with a blank secret keeps the stored Secret — zero cluster calls", %{conn: conn} do
      {user, instance} = member_with_instance()
      setting = setting!(instance)
      pat = ApiPat.mint!(user.email, ["backups:write"])

      # A blank form field is "leave the credentials alone": no
      # kubeconfig, no Secret read, no Secret write.
      reject(K8s, :kubeconfig, 1)
      reject(Secret, :get_data, 3)
      reject(Secret, :create, 4)

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/backup-settings/#{setting.id}", %{
          "data" => %{
            "type" => "backup_setting",
            "id" => setting.id,
            "attributes" => %{"retention_keep" => 14, "secret_access_key" => ""}
          }
        })

      assert %{"data" => %{"attributes" => attrs}} = json_response(conn, 200)
      assert attrs["retention_keep"] == 14
      refute Map.has_key?(attrs, "secret_access_key")

      assert {:ok, _row} = BackupSetting.get_by_instance(instance.id, actor: user)
    end

    test "PATCH with a new secret rotates the key, preserving the repo password byte-for-byte",
         %{conn: conn} do
      {user, instance} = member_with_instance()
      setting = setting!(instance)
      pat = ApiPat.mint!(user.email, ["backups:write"])

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stored = %{
        "RESTIC_REPOSITORY" => "s3:https://account.r2.cloudflarestorage.com/fluxvale-kavita",
        "RESTIC_PASSWORD" => "stored-repo-password",
        "AWS_ACCESS_KEY_ID" => "AKIAIOSFODNN7EXAMPLE",
        "AWS_SECRET_ACCESS_KEY" => "stored-secret"
      }

      expect(Secret, :get_data, fn _kc, ns, "backup-config" ->
        assert ns == "fluxvale-app-#{instance.id}"
        {:ok, stored}
      end)

      expect(Secret, :create, fn _kc, _ns, "backup-config", data ->
        # The repo password is the repo's identity — byte-for-byte.
        assert data["RESTIC_PASSWORD"] == "stored-repo-password"
        assert data["AWS_SECRET_ACCESS_KEY"] == "rotated-provider-secret"
        {:ok, %{}}
      end)

      reject(ResourceQuota, :create, 4)

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/backup-settings/#{setting.id}", %{
          "data" => %{
            "type" => "backup_setting",
            "id" => setting.id,
            "attributes" => %{"secret_access_key" => "rotated-provider-secret"}
          }
        })

      assert %{"data" => _row} = json_response(conn, 200)
    end

    test "a Secret apply failure fails the save — no row persists", %{conn: conn} do
      {user, instance} = member_with_instance()
      pat = ApiPat.mint!(user.email, ["backups:write"])

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(Secret, :get_data, fn _kc, _ns, _n -> {:error, %Error{reason: :not_found}} end)

      stub(Secret, :create, fn _kc, _ns, _n, _d ->
        {:error, Error.connection_error("rejected")}
      end)

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/backup-setting", %{
          "data" => %{
            "type" => "backup_setting",
            "attributes" => %{
              "endpoint" => "https://account.r2.cloudflarestorage.com",
              "bucket" => "fluxvale-kavita",
              "access_key_id" => "AKIAIOSFODNN7EXAMPLE",
              "secret_access_key" => "provider-secret-value"
            }
          }
        })

      # The K8s error surfaces raw (the restore route's stance) and the
      # after_action failure rolls the row back — nothing persists.
      assert %{"errors" => [%{"status" => "500"} | _rest]} = json_response(conn, 500)

      assert {:error, _not_found} = BackupSetting.get_by_instance(instance.id, actor: user)
    end
  end

  describe "PATCH /api/v1/backup-settings/:id" do
    test "saves the row's fields", %{conn: conn} do
      {user, instance} = member_with_instance()
      setting = setting!(instance)
      pat = ApiPat.mint!(user.email, ["backups:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/backup-settings/#{setting.id}", %{
          "data" => %{
            "type" => "backup_setting",
            "id" => setting.id,
            "attributes" => %{"enabled" => false}
          }
        })

      assert %{"data" => %{"attributes" => %{"enabled" => false}}} = json_response(conn, 200)
    end
  end

  describe "DELETE /api/v1/backup-settings/:id" do
    test "removes the row (the stop-backing-up verb)", %{conn: conn} do
      {user, instance} = member_with_instance()
      setting = setting!(instance)
      pat = ApiPat.mint!(user.email, ["backups:write"])

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/backup-settings/#{setting.id}")

      assert conn.status == 200

      assert {:error, _not_found} =
               BackupSetting.get_by_instance(instance.id, actor: user)
    end
  end

  describe "GET /api/v1/instances/:instance_id/backup-runs" do
    test "lists the history newest-first with the ?limit argument", %{conn: conn} do
      {user, instance} = member_with_instance()
      # Creation order is the history order: started_at is second-
      # precision, so the id (uuidv7) tiebreak carries the ordering.
      _older = run!(instance, %{kind: :scheduled, snapshot_id: String.duplicate("b", 64)})
      _newest = run!(instance, %{kind: :manual, snapshot_id: String.duplicate("a", 64)})
      pat = ApiPat.mint!(user.email, ["backups:write"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/instances/#{instance.id}/backup-runs?limit=1")

      assert %{"data" => [row]} = json_response(conn, 200)
      assert row["type"] == "backup_run"
      assert row["attributes"]["kind"] == "manual"
    end
  end

  describe "POST /api/v1/instances/:id/backup-runs" do
    test "runs a manual backup (K8s stubbed) — 201 with the run row", %{conn: conn} do
      stub_backup_cluster()
      {user, instance} = member_with_instance()
      setting!(instance)
      pat = ApiPat.mint!(user.email, ["backups:write"])

      conn =
        conn
        |> auth(pat)
        |> post("/api/v1/instances/#{instance.id}/backup-runs")

      # Generic-action shape: flat, the run's public attributes.
      assert body = json_response(conn, 201)
      assert body["kind"] == "manual"
      assert body["status"] == "running"
      assert body["instance_id"] == instance.id
    end

    test "an unconfigured instance refuses with the operation's own words", %{conn: conn} do
      {user, instance} = member_with_instance()
      pat = ApiPat.mint!(user.email, ["backups:write"])

      conn =
        conn
        |> auth(pat)
        |> post("/api/v1/instances/#{instance.id}/backup-runs")

      # 400: ash_json_api maps a generic action's :invalid class here.
      assert %{"errors" => [error]} = json_response(conn, 400)
      assert error["detail"] =~ "backups are not configured"
    end
  end

  describe "POST /api/v1/instances/:id/backup-runs/:backup_run_id/restore" do
    test "restores the newest successful snapshot (K8s stubbed) — 201", %{conn: conn} do
      stub_restore_cluster()
      {user, instance} = member_with_instance()
      setting!(instance)
      newest = run!(instance, %{snapshot_id: String.duplicate("c", 64)})
      pat = ApiPat.mint!(user.email, ["backups:write"])

      conn =
        conn
        |> auth(pat)
        |> post("/api/v1/instances/#{instance.id}/backup-runs/#{newest.id}/restore")

      assert body = json_response(conn, 201)
      assert body["kind"] == "restore"
      assert body["status"] == "running"
      assert body["restored_from"] == "running"
    end

    test "a run id that is not the newest successful backup is refused — the path never lies", %{
      conn: conn
    } do
      stub_restore_cluster()
      {user, instance} = member_with_instance()
      setting!(instance)

      # Two succeeded runs, creation order = restore-target order (the
      # id tiebreak carries same-second ordering).
      older = run!(instance, %{snapshot_id: String.duplicate("d", 64)})
      _newest = run!(instance, %{snapshot_id: String.duplicate("e", 64)})

      pat = ApiPat.mint!(user.email, ["backups:write"])

      conn =
        conn
        |> auth(pat)
        |> post("/api/v1/instances/#{instance.id}/backup-runs/#{older.id}/restore")

      assert %{"errors" => [%{"detail" => detail}]} = json_response(conn, 400)
      assert detail =~ "not the latest successful backup"
    end

    test "no finished backup yet is refused in plain words", %{conn: conn} do
      stub_restore_cluster()
      {user, instance} = member_with_instance()
      setting!(instance)
      pat = ApiPat.mint!(user.email, ["backups:write"])

      conn =
        conn
        |> auth(pat)
        |> post("/api/v1/instances/#{instance.id}/backup-runs/#{instance.id}/restore")

      assert %{"errors" => [%{"detail" => detail}]} = json_response(conn, 400)
      assert detail =~ "there is no finished backup to restore yet"
    end

    test "a cluster failure mid-restore settles the run and surfaces the raw error", %{
      conn: conn
    } do
      stub_restore_cluster()

      # The scale-down is the restore's first cluster write — failing it
      # exercises the passthrough: the K8s error rides out untouched
      # (the :delete action's stance), never mapped to guard copy.
      stub(Deployment, :scale, fn _kc, _ns, _n, _r ->
        {:error, %Error{reason: :timeout, message: "scale timed out"}}
      end)

      {user, instance} = member_with_instance()
      setting!(instance)
      _newest = run!(instance, %{snapshot_id: String.duplicate("f", 64)})
      pat = ApiPat.mint!(user.email, ["backups:write"])

      conn =
        conn
        |> auth(pat)
        |> post("/api/v1/instances/#{instance.id}/backup-runs/#{newest_run_id(instance)}/restore")

      assert %{"errors" => [%{"status" => "500"} | _rest]} = json_response(conn, 500)

      # The op's own contract: the run row settles :failed (the
      # failure-before-the-Job rule), so the slot frees for a retry.
      assert [%{status: :failed}] =
               FluxVale.Infrastructure.BackupRun
               |> Ash.Query.filter(instance_id == ^instance.id and kind == :restore)
               |> Ash.read!(authorize?: false)
    end
  end

  # The restore route names its target — read the newest succeeded run
  # the same way the action does (started_at desc, id desc).
  defp newest_run_id(instance) do
    FluxVale.Infrastructure.BackupRun
    |> Ash.Query.filter(
      instance_id == ^instance.id and kind in [:scheduled, :manual] and
        status == :succeeded and not is_nil(snapshot_id)
    )
    |> Ash.Query.sort(started_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
    |> Map.fetch!(:id)
  end
end
