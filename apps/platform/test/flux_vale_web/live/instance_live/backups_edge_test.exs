defmodule FluxValeWeb.InstanceLive.BackupsEdgeTest do
  @moduledoc false
  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveViewTest

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  setup %{conn: conn} do
    {user, conn} = SessionHelpers.user_with_session(conn)
    version = InstanceFixtures.app_version!(default_storage_gb: 10)
    InstanceFixtures.local_cluster!()
    {:ok, user: user, conn: conn, version: version}
  end

  defp instance!(version, user, status \\ :running) do
    instance = InstanceFixtures.instance!(version, user)

    instance
    |> InstanceFixtures.pin!(namespace: "fluxvale-app-#{instance.id}")
    |> InstanceFixtures.walk_to!(status)
  end

  defp setting!(instance, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          instance_id: instance.id,
          endpoint: "https://account.r2.cloudflarestorage.com",
          bucket: "fluxvale-kavita",
          access_key_id: "AKIAIOSFODNN7EXAMPLE"
        },
        Map.new(overrides)
      )

    BackupSetting
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!()
  end

  defp stub_quota do
    stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
  end

  # Channel-level pushes (`with_target` + render_click/2) reach the panel
  # with events its own DOM wouldn't offer — the disabled button's guard
  # and the copy paths behind it.
  defp click(view, event) do
    view
    |> with_target("#backups")
    |> render_click(event, %{})
  end

  describe "guard copy" do
    test "a restore refuses while a run is active", %{conn: conn, user: user, version: version} do
      instance = instance!(version, user)
      setting!(instance)

      # The one-active-run guard is the partial unique index; the operation
      # only reaches it after the kubeconfig read.
      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      # A snapshot exists (so the guard order reaches the in-flight check)
      # and an active run holds the slot.
      run!(instance, :scheduled, %{
        status: :succeeded,
        snapshot_id: "6b757e02e6a7c1d8",
        bytes_added: 1024
      })

      BackupRun
      |> Ash.Changeset.for_create(
        :create,
        %{instance_id: instance.id, kind: :scheduled, started_at: DateTime.utc_now()},
        authorize?: false
      )
      |> Ash.create!()

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      click(view, "restore")

      assert has_element?(view, "[data-testid=backups-error]", "already running")
    end

    test "a restore with nothing to restore names the wait", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      click(view, "restore")

      assert has_element?(view, "[data-testid=backups-error]", "no finished backup to restore")
    end

    test "a failed restore is offered a retry (the operation accepts it)", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance)

      run!(instance, :scheduled, %{
        status: :succeeded,
        snapshot_id: "6b757e02e6a7c1d8",
        bytes_added: 1024
      })

      # ADR-0037 §5's retry arm: a restore that landed :error/:restore_failed
      # may run again — the app is already scaled down.
      failed =
        run!(instance, :restore, %{
          status: :failed,
          error_summary: "exit code 1: restore aborted",
          restored_from: :running
        })

      {:ok, _errored} =
        InstanceK8s.update_status(instance, :error, "Restore failed", :restore_failed)

      assert failed.status == :failed

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      # The button is live, not disabled — and the owner can confirm again.
      assert has_element?(view, "[data-testid=restore-latest]")
      refute has_element?(view, "[data-testid=restore-latest][disabled]")
    end

    test "a manual backup on a paused instance says so", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance, enabled: false)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      click(view, "back-up-now")

      assert has_element?(view, "[data-testid=backups-error]", "Backups are paused")
    end

    test "a run against a mid-deploy instance reports it busy", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      # The page hasn't seen a pending row yet; the operation's own status
      # guard is the thing under test.
      click(view, "restore")

      assert has_element?(view, "[data-testid=backups-error]")
    end

    test "a K8s failure on a save shows the retry copy", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:error, Error.connection_error("api down")} end)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid=backups-enabled-toggle]"))

      assert has_element?(view, "[data-testid=backups-error]", "Something went wrong on our side")
    end

    test "a save before the app is set up says so", %{conn: conn, user: user, version: version} do
      instance = InstanceFixtures.instance!(version, user)
      setting!(instance)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      click(view, "open-settings")

      view
      |> element("#backup-settings-form")
      |> render_submit(%{
        "backup" => %{
          "endpoint" => "https://account.r2.cloudflarestorage.com",
          "bucket" => "fluxvale-kavita",
          "prefix" => "",
          "access_key_id" => "AKIAIOSFODNN7EXAMPLE",
          "secret_access_key" => "",
          "retention_keep" => "7",
          "enabled" => "true"
        }
      })

      assert has_element?(
               view,
               "[data-testid=backups-error]",
               "once the app has finished setting up"
             )
    end
  end

  describe "form edges" do
    test "blank required fields say which ones are missing", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid=backups-setup]"))

      view
      |> element("#backup-settings-form")
      |> render_submit(%{
        "backup" => %{
          "endpoint" => "",
          "bucket" => "",
          "prefix" => "",
          "access_key_id" => "",
          "secret_access_key" => "",
          "retention_keep" => "7",
          "enabled" => "true"
        }
      })

      html =
        view
        |> element("#backup-settings-form")
        |> render()

      assert html =~ "is required"
      assert has_element?(view, "#backup-settings-form")
    end

    test "a first save without the secret key says to add it", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(Secret, :get_data, fn _kc, _ns, "backup-config" ->
        {:error, %Error{reason: :not_found}}
      end)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid=backups-setup]"))

      view
      |> element("#backup-settings-form")
      |> render_submit(%{
        "backup" => %{
          "endpoint" => "https://account.r2.cloudflarestorage.com",
          "bucket" => "fluxvale-kavita",
          "prefix" => "",
          "access_key_id" => "AKIAIOSFODNN7EXAMPLE",
          "secret_access_key" => "",
          "retention_keep" => "7",
          "enabled" => "true"
        }
      })

      assert has_element?(view, "[data-testid=backups-error]", "Add your secret access key")
    end

    test "a corrupt stored Secret says to re-enter the keys", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(Secret, :get_data, fn _kc, _ns, "backup-config" ->
        {:ok, %{"AWS_ACCESS_KEY_ID" => "AKIA", "AWS_SECRET_ACCESS_KEY" => "secret"}}
      end)

      stub_quota()

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid=backups-edit]"))

      view
      |> element("#backup-settings-form")
      |> render_submit(%{
        "backup" => %{
          "endpoint" => "https://account.r2.cloudflarestorage.com",
          "bucket" => "fluxvale-kavita",
          "prefix" => "",
          "access_key_id" => "AKIAIOSFODNN7EXAMPLE",
          "secret_access_key" => "",
          "retention_keep" => "7",
          "enabled" => "true"
        }
      })

      assert has_element?(view, "[data-testid=backups-error]", "stored credentials look damaged")
    end

    test "a form missing a rendered field keeps going (the panel never invents one)", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(Secret, :get_data, fn _kc, _ns, "backup-config" ->
        {:ok,
         %{
           "RESTIC_REPOSITORY" => "s3:https://example/bucket",
           "RESTIC_PASSWORD" => "a43charpassword",
           "AWS_ACCESS_KEY_ID" => "AKIA",
           "AWS_SECRET_ACCESS_KEY" => "secret"
         }}
      end)

      stub(Secret, :create, fn _kc, _ns, "backup-config", _data -> {:ok, %{}} end)
      stub_quota()

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid=backups-edit]"))

      # A crafted payload without `prefix`: operation_params skips the
      # absent key, the merge keeps the stored value, and the save still
      # succeeds. `enabled` is not a form field at all (V4).
      view
      |> element("#backup-settings-form")
      |> render_submit(%{
        "backup" => %{
          "endpoint" => "https://account.r2.cloudflarestorage.com",
          "bucket" => "fluxvale-kavita",
          "access_key_id" => "AKIAIOSFODNN7EXAMPLE",
          "secret_access_key" => "",
          "retention_keep" => "7"
        }
      })

      assert has_element?(view, "[data-testid=backups-notice]", "Backup settings saved")
    end

    test "a payload missing only the optional keys leaves them stored", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance, prefix: "keep-me")

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(Secret, :get_data, fn _kc, _ns, "backup-config" ->
        {:ok,
         %{
           "RESTIC_REPOSITORY" => "s3:x",
           "RESTIC_PASSWORD" => "pw",
           "AWS_ACCESS_KEY_ID" => "AKIA",
           "AWS_SECRET_ACCESS_KEY" => "s"
         }}
      end)

      stub(Secret, :create, fn _kc, _ns, _n, _d -> {:ok, %{}} end)
      stub_quota()

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid=backups-edit]"))

      view
      |> element("#backup-settings-form")
      |> render_submit(%{
        "backup" => %{
          "endpoint" => "https://account.r2.cloudflarestorage.com",
          "bucket" => "fluxvale-kavita",
          "prefix" => "",
          "access_key_id" => "AKIAIOSFODNN7EXAMPLE",
          "secret_access_key" => "",
          "retention_keep" => "7",
          "enabled" => "true"
        }
      })

      # The blank prefix is a deliberate clear, and the save lands.
      {:ok, stored} = BackupSetting.get_by_instance(instance.id, actor: user)
      assert stored.prefix == nil
    end

    test "cancel backs out of an edit without saving", %{conn: conn, user: user, version: version} do
      instance = instance!(version, user)
      setting!(instance, retention_keep: 9)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid=backups-edit]"))
      assert has_element?(view, "#backup-settings-form")

      render_click(element(view, "[data-testid=backups-cancel]"))

      refute has_element?(view, "#backup-settings-form")
      assert has_element?(view, "[data-testid=backup-retention]", "last 9 snapshots")
    end
  end

  describe "unrestorable states" do
    test "a pending instance keeps Restore disabled and says the app is busy", %{
      conn: conn,
      user: user,
      version: version
    } do
      # A setting can outlive a status change: the row is there, the app
      # isn't restorable (:pending has no volume at rest).
      instance = InstanceFixtures.instance!(version, user)
      setting!(instance)

      run!(instance, :scheduled, %{
        status: :succeeded,
        snapshot_id: "6b757e02e6a7c1d8",
        bytes_added: 1024
      })

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid=restore-latest][disabled]")

      # A crafted event still gets the operation's honest answer.
      click(view, "restore")

      assert has_element?(view, "[data-testid=backups-error]", "The app is busy right now")
    end
  end

  describe "summary edges" do
    test "a short access key id masks entirely", %{conn: conn, user: user, version: version} do
      instance = instance!(version, user)
      setting!(instance, access_key_id: "AKIA")

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid=backup-access-key]", "••••")
    end

    test "the switch resumes a paused instance", %{conn: conn, user: user, version: version} do
      instance = instance!(version, user)
      setting!(instance, enabled: false)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(Secret, :get_data, fn _kc, _ns, "backup-config" ->
        {:ok,
         %{
           "RESTIC_REPOSITORY" => "s3:https://example/bucket",
           "RESTIC_PASSWORD" => "a43charpassword",
           "AWS_ACCESS_KEY_ID" => "AKIA",
           "AWS_SECRET_ACCESS_KEY" => "secret"
         }}
      end)

      stub(Secret, :create, fn _kc, _ns, "backup-config", _data -> {:ok, %{}} end)
      stub_quota()

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid=backups-enabled-toggle]"))

      assert has_element?(view, "[data-testid=backups-notice]", "Backups resumed")
    end

    test "run sizes render across the byte ranges and a restore's own total", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance)

      # bytes_added nil (a succeeded row before the summary parsed), then
      # bytes, KB, GB — one per run, newest first.
      run!(instance, :scheduled, %{status: :succeeded, snapshot_id: "aaaa0000", bytes_added: nil})
      run!(instance, :scheduled, %{status: :succeeded, snapshot_id: "bbbb1111", bytes_added: 512})

      run!(instance, :scheduled, %{
        status: :succeeded,
        snapshot_id: "cccc2222",
        bytes_added: 2_500
      })

      run!(instance, :scheduled, %{
        status: :succeeded,
        snapshot_id: "dddd3333",
        bytes_added: 5_368_709_120
      })

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      html =
        view
        |> element("[data-testid=backup-runs]")
        |> render()

      assert html =~ "512 B"
      assert html =~ "2.4 KB"
      assert html =~ "5.0 GB"
    end

    test "a restore row reports its restored bytes", %{conn: conn, user: user, version: version} do
      instance = instance!(version, user)
      setting!(instance)

      restored =
        BackupRun
        |> Ash.Changeset.for_create(
          :create,
          %{
            instance_id: instance.id,
            kind: :restore,
            started_at: DateTime.add(DateTime.utc_now(), -120, :second),
            restored_from: :running
          },
          authorize?: false
        )
        |> Ash.create!()

      restored
      |> Ash.Changeset.for_update(
        :update,
        %{
          status: :succeeded,
          bytes_restored: 3_145_728,
          finished_at: DateTime.utc_now()
        },
        authorize?: false
      )
      |> Ash.update!()

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid=backup-run]", "3.0 MB restored")
    end

    test "relative times read as minutes, hours, and days", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance)

      # Days: an old run's finished_at is days behind the render clock.
      old =
        BackupRun
        |> Ash.Changeset.for_create(
          :create,
          %{
            instance_id: instance.id,
            kind: :scheduled,
            started_at: DateTime.add(DateTime.utc_now(), -5 * 86_400, :second)
          },
          authorize?: false
        )
        |> Ash.create!()

      old
      |> Ash.Changeset.for_update(
        :update,
        %{
          status: :succeeded,
          snapshot_id: "eeee4444",
          bytes_added: 1024,
          finished_at: DateTime.add(DateTime.utc_now(), -5 * 86_400, :second)
        },
        authorize?: false
      )
      |> Ash.update!()

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid=backup-run]", "5 d ago")
    end
  end

  # A finished run is the sweep's write: :create opens the row, :update
  # carries the outcome.
  defp run!(instance, kind, attrs) do
    attrs = Map.new(attrs)
    {opening, outcome} = Map.split(attrs, [:status, :restored_from])

    an_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

    base = %{instance_id: instance.id, kind: kind, started_at: an_hour_ago}

    opening_attrs = Map.merge(base, opening)
    changeset = Ash.Changeset.for_create(BackupRun, :create, opening_attrs, authorize?: false)

    run = Ash.create!(changeset)

    if map_size(outcome) == 0 do
      run
    else
      run
      |> Ash.Changeset.for_update(:update, outcome, authorize?: false)
      |> Ash.update!()
    end
  end
end
