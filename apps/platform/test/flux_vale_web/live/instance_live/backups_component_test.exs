defmodule FluxValeWeb.InstanceLive.BackupsComponentTest do
  @moduledoc false

  # The backups panel (#222, ADR-0037): the unconfigured callout, the
  # configured summary, the settings form (resource-owned validation
  # messages inline), the masked access key, the repo-password reveal,
  # the manual trigger, and the two-step restore/stop confirms.
  #
  # Mounted through the real instance page, not a bare
  # `live_isolated` component: the panel's reads are the page's actor
  # (`current_user`) and its refresh rides the page's re-render, so the
  # page is the honest harness — a component-only test could pass while
  # the wiring was wrong.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import FluxVale.TestSupport.AccountsFixtures
  import FluxVale.TestSupport.NoK8sLeaks
  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.BackupJob
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.RestoreJob
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @s3_endpoint "https://account.r2.cloudflarestorage.com"
  @bucket "fluxvale-kavita"
  @access_key "AKIAIOSFODNN7EXAMPLE"
  @secret_key "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  @repo_password "Q2hhbmdlVGhpc1RvQVNlY3JldEFuZEtlZXBJdFNhZmU"

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

  # The settings row is ConfigureBackups' output; a precondition here is
  # built through the action (the repo's test-data stance).
  defp setting!(instance, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          instance_id: instance.id,
          endpoint: @s3_endpoint,
          bucket: @bucket,
          access_key_id: @access_key
        },
        Map.new(overrides)
      )

    BackupSetting
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!()
  end

  # A finished run is the sweep's write: :create accepts the opening
  # fields only, so the outcome rides :update (the real path).
  defp run!(instance, attrs) do
    attrs = Map.new(attrs)

    {opening, outcome} =
      Map.split(attrs, [:status, :restored_from, :started_at, :kind, :instance_id])

    base = %{
      instance_id: instance.id,
      kind: :scheduled,
      started_at: DateTime.add(DateTime.utc_now(), -3600, :second)
    }

    run =
      base
      |> Map.merge(opening)
      |> then(&Ash.Changeset.for_create(BackupRun, :create, &1, authorize?: false))
      |> Ash.create!()

    if map_size(outcome) == 0 do
      run
    else
      run
      |> Ash.Changeset.for_update(
        :update,
        Map.put(outcome, :finished_at, DateTime.utc_now()),
        authorize?: false
      )
      |> Ash.update!()
    end
  end

  defp stub_backup_k8s do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
    stub(BackupJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _replicas -> {:ok, %{}} end)
    stub(RestoreJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
    stub(RestoreJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
  end

  describe "unconfigured" do
    test "explains BYO storage and offers setup", %{conn: conn, user: user, version: version} do
      instance = instance!(version, user)
      {:ok, view, html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid=backups-panel]")

      assert has_element?(
               view,
               "[data-testid=backups-unconfigured]",
               "your own S3-compatible bucket"
             )

      assert has_element?(view, "[data-testid=backups-unconfigured]", "FluxVale adds no charge")
      assert has_element?(view, "[data-testid=backups-setup]", "Set up backups")
      refute has_element?(view, "[data-testid=backup-settings-form]")
      refute has_element?(view, "[data-testid=back-up-now]")
      refute_k8s_terms(html)
    end

    test "setup opens the form with the resource's defaults", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid=backups-setup]"))

      assert has_element?(view, "#backup-settings-form")
      assert has_element?(view, "input[name='backup[endpoint]']")
      assert has_element?(view, "input[name='backup[bucket]']")
      assert has_element?(view, "input[name='backup[prefix]']")
      assert has_element?(view, "input[name='backup[access_key_id]']")
      assert has_element?(view, "input[type=password][name='backup[secret_access_key]']")
      assert has_element?(view, "input[name='backup[retention_keep]'][value='7']")
      assert has_element?(view, "input[type=checkbox][name='backup[enabled]']")

      # The blank secret means "keep the current one" — said in the label.
      assert has_element?(
               view,
               "label[for='backup_secret_access_key']",
               "leave blank to keep the current one"
             )
    end

    test "a never-deployed instance is not offered setup", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = InstanceFixtures.instance!(version, user)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid=backups-unconfigured]")
      refute has_element?(view, "[data-testid=backups-setup]")
    end

    test "invalid settings render the resource's messages inline", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid=backups-setup]"))

      html =
        view
        |> element("#backup-settings-form")
        |> render_submit(%{
          "backup" => %{
            "endpoint" => "ftp://bucket.example",
            "bucket" => "AB",
            "access_key_id" => @access_key,
            "secret_access_key" => @secret_key,
            "retention_keep" => "99",
            "enabled" => "true"
          }
        })

      # The messages are the resource's own (the fence's words), surfaced
      # plainly — the form stays open, nothing was saved.
      assert html =~ "must be an http:// or https:// URL with a host and no path"
      assert html =~ "must be 3-63 lowercase letters"
      assert html =~ "must be less than or equal to 30"
      assert has_element?(view, "#backup-settings-form")
      refute has_element?(view, "[data-testid=backups-health]")

      assert BackupSetting.get_by_instance(instance.id, actor: user) == {:error, :not_found} or
               match?({:error, _}, BackupSetting.get_by_instance(instance.id, actor: user))
    end
  end

  describe "configured" do
    test "summarises the destination and masks the access key", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance, retention_keep: 14, prefix: "fluxvale/kavita")

      {:ok, view, html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid=backup-endpoint]", @s3_endpoint)
      assert has_element?(view, "[data-testid=backup-bucket]", @bucket)
      assert has_element?(view, "[data-testid=backup-bucket-hint]", "fluxvale/kavita")
      assert has_element?(view, "[data-testid=backup-access-key]", "••••MPLE")
      assert has_element?(view, "[data-testid=backup-retention]", "last 14 snapshots")
      assert has_element?(view, "[data-testid=backups-enabled-toggle]", "Pause backups")

      # The full key never renders, and the secret key was never stored.
      refute html =~ @access_key
      refute html =~ @secret_key
      refute_k8s_terms(html)
    end

    test "never-run, healthy, and failing states read differently", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")
      assert has_element?(view, "[data-testid=backups-health]", "Not run yet")
      assert has_element?(view, "[data-testid=backups-no-runs]")
      assert has_element?(view, "[data-testid=restore-latest][disabled]")

      run!(instance, %{
        status: :succeeded,
        snapshot_id: "6b757e02e6a7c1d8",
        bytes_added: 2_097_152
      })

      render(view)
      assert has_element?(view, "[data-testid=backups-health]", "Healthy")
      assert has_element?(view, "[data-testid=backup-run][data-run-status=succeeded]")
      assert has_element?(view, "[data-testid=backup-run]", "6b757e02")
      assert has_element?(view, "[data-testid=backup-run]", "2.0 MB added")
      refute has_element?(view, "[data-testid=restore-latest][disabled]")

      run!(instance, %{
        started_at: DateTime.utc_now(),
        status: :failed,
        error_summary: "exit code 1: repository is already locked"
      })

      render(view)
      assert has_element?(view, "[data-testid=backups-health]", "Needs attention")
      assert has_element?(view, "[data-testid=backups-failing]", "repository is already locked")
      assert has_element?(view, "[data-testid=backup-run][data-run-status=failed]")
    end

    test "an active run disables the trigger and shows its row", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance)
      run!(instance, %{status: :running, started_at: DateTime.utc_now()})

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid=back-up-now][disabled]")
      assert has_element?(view, "[data-testid=backup-run][data-run-status=running]")
      assert has_element?(view, "[data-testid=backups-health]", "Running")

      # A restore is refused while anything is active — the operation's
      # guard, mirrored by the disabled button.
      assert has_element?(view, "[data-testid=restore-latest][disabled]")
    end

    test "the panel adds restore detail while the instance is restoring", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance)

      run!(instance, %{
        status: :succeeded,
        snapshot_id: "6b757e02e6a7c1d8",
        bytes_added: 1024
      })

      {:ok, _run} =
        BackupRun
        |> Ash.Changeset.for_create(
          :create,
          %{
            instance_id: instance.id,
            kind: :restore,
            status: :pending,
            started_at: DateTime.utc_now(),
            restored_from: :running
          },
          authorize?: false
        )
        |> Ash.create()

      {:ok, _restoring} = InstanceK8s.update_status(instance, :restoring, "Restoring a backup…")

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid=backups-restoring]")
      assert has_element?(view, "[data-testid=status-badge]", "Restoring")
      assert has_element?(view, "[data-testid=backup-run][data-run-kind=restore]")
      refute has_element?(view, "[data-testid=restore-latest]")
    end

    test "the enabled switch rides a settings save", %{conn: conn, user: user, version: version} do
      instance = instance!(version, user)
      setting!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(Secret, :get_data, fn _kc, _ns, "backup-config" ->
        {:ok,
         %{
           "RESTIC_REPOSITORY" => "s3:#{@s3_endpoint}/#{@bucket}",
           "RESTIC_PASSWORD" => @repo_password,
           "AWS_ACCESS_KEY_ID" => @access_key,
           "AWS_SECRET_ACCESS_KEY" => @secret_key
         }}
      end)

      stub(Secret, :create, fn _kc, _ns, "backup-config", _data -> {:ok, %{}} end)

      stub(FluxVale.Clients.K8s.Resources.ResourceQuota, :create, fn _kc, _ns, _n, _spec ->
        {:ok, %{}}
      end)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid=backups-enabled-toggle]"))

      assert has_element?(view, "[data-testid=backups-enabled-toggle]", "Resume backups")
      assert has_element?(view, "[data-testid=backups-notice]", "Backups paused")

      {:ok, stored} = BackupSetting.get_by_instance(instance.id, actor: user)
      refute stored.enabled
    end

    test "the settings form saves and re-reads the row", %{
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
           "RESTIC_REPOSITORY" => "s3:#{@s3_endpoint}/#{@bucket}",
           "RESTIC_PASSWORD" => @repo_password,
           "AWS_ACCESS_KEY_ID" => @access_key,
           "AWS_SECRET_ACCESS_KEY" => @secret_key
         }}
      end)

      stub(Secret, :create, fn _kc, _ns, "backup-config", _data -> {:ok, %{}} end)

      stub(FluxVale.Clients.K8s.Resources.ResourceQuota, :create, fn _kc, _ns, _n, _spec ->
        {:ok, %{}}
      end)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid=backups-edit]"))

      view
      |> element("#backup-settings-form")
      |> render_submit(%{
        "backup" => %{
          "endpoint" => @s3_endpoint,
          "bucket" => @bucket,
          "prefix" => "fluxvale/kavita",
          "access_key_id" => @access_key,
          "secret_access_key" => "",
          "retention_keep" => "21",
          "enabled" => "true"
        }
      })

      assert has_element?(view, "[data-testid=backups-notice]", "Backup settings saved")
      refute has_element?(view, "#backup-settings-form")
      assert has_element?(view, "[data-testid=backup-retention]", "last 21 snapshots")
      assert has_element?(view, "[data-testid=backup-bucket-hint]", "fluxvale/kavita")

      {:ok, stored} = BackupSetting.get_by_instance(instance.id, actor: user)
      assert stored.retention_keep == 21
      assert stored.prefix == "fluxvale/kavita"
    end
  end

  describe "the repo password" do
    test "is masked until revealed, then copies the exact string", %{
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
           "RESTIC_REPOSITORY" => "s3:#{@s3_endpoint}/#{@bucket}",
           "RESTIC_PASSWORD" => @repo_password,
           "AWS_ACCESS_KEY_ID" => @access_key,
           "AWS_SECRET_ACCESS_KEY" => @secret_key
         }}
      end)

      {:ok, view, html} = live(conn, ~p"/instances/#{instance.id}")

      refute html =~ @repo_password
      refute has_element?(view, "[data-testid=repo-password]")
      assert has_element?(view, "[data-testid=reveal-repo-password]", "Show password")
      assert has_element?(view, "[data-testid=backups-panel]", "Keep this somewhere safe")

      render_click(element(view, "[data-testid=reveal-repo-password]"))

      assert has_element?(view, "[data-testid=repo-password]", @repo_password)

      assert has_element?(
               view,
               "[data-testid=copy-repo-password][data-copy-value='#{@repo_password}']"
             )

      password_html =
        view
        |> element("[data-testid=repo-password]")
        |> render()

      assert password_html =~ "whitespace-nowrap"

      render_click(element(view, "[data-testid=hide-repo-password]"))
      refute has_element?(view, "[data-testid=repo-password]")
    end

    test "a missing Secret flashes instead of crashing", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(Secret, :get_data, fn _kc, _ns, "backup-config" ->
        {:error, %Error{reason: :not_found}}
      end)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid=reveal-repo-password]"))

      assert render(view) =~ "Couldn&#39;t read the backup password"
      refute has_element?(view, "[data-testid=repo-password]")
    end

    test "a never-deployed instance gets the setup copy", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = InstanceFixtures.instance!(version, user)
      setting!(instance)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid=reveal-repo-password]"))

      assert has_element?(view, "[data-testid=backups-error]", "no backup password yet")
    end
  end

  describe "manual backup" do
    test "Back up now starts a run and re-reads it", %{conn: conn, user: user, version: version} do
      instance = instance!(version, user)
      setting!(instance)
      stub_backup_k8s()

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid=back-up-now]"))

      assert has_element?(view, "[data-testid=backups-notice]", "Backup started")
      assert has_element?(view, "[data-testid=backup-run][data-run-kind=manual]")
      assert has_element?(view, "[data-testid=back-up-now][disabled]")
    end

    test "a guard failure renders the plain-words reason", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance, enabled: false)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      # The button is offered (paused is a settings state, not a broken
      # one); the operation owns the refusal and the panel says why.
      render_click(element(view, "[data-testid=back-up-now]"))

      assert has_element?(view, "[data-testid=backups-error]", "Backups are paused")
    end
  end

  describe "restore" do
    test "is a two-step confirm with the destructive copy", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance)
      run!(instance, %{status: :succeeded, snapshot_id: "6b757e02e6a7c1d8", bytes_added: 1024})
      stub_backup_k8s()

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      # Step 1: the owner must read the consequence before the action exists.
      refute has_element?(view, "[data-testid=restore-confirm]")

      render_click(element(view, "[data-testid=restore-latest]"))

      assert has_element?(
               view,
               "[data-testid=restore-confirm]",
               "Yes, restore the last backup"
             )

      assert render(view) =~
               "This replaces the app&#39;s current data with the last backup. This cannot be undone."

      # Cancel backs out without touching anything.
      render_click(element(view, "[data-testid=restore-cancel]"))
      refute has_element?(view, "[data-testid=restore-confirm]")

      # Step 2: the confirmed click runs the restore.
      render_click(element(view, "[data-testid=restore-latest]"))
      render_click(element(view, "[data-testid=restore-confirm]"))

      assert has_element?(view, "[data-testid=backups-notice]", "Restoring now")
      assert has_element?(view, "[data-testid=status-badge]", "Restoring")
      assert has_element?(view, "[data-testid=backup-run][data-run-kind=restore]")
    end

    test "a restore failure flips the instance and states the fallback", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance)
      run!(instance, %{status: :succeeded, snapshot_id: "6b757e02e6a7c1d8", bytes_added: 1024})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(Deployment, :scale, fn _kc, _ns, _n, _replicas -> {:ok, %{}} end)
      stub(RestoreJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)

      stub(RestoreJob, :create, fn _kc, _ns, _spec ->
        {:error, Error.connection_error("api hiccup")}
      end)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      render_click(element(view, "[data-testid=restore-latest]"))
      render_click(element(view, "[data-testid=restore-confirm]"))

      # The operation errors, the panel re-reads, and the page's own
      # failure copy carries the next step (the run row says why).
      assert has_element?(view, "[data-testid=status-badge]", "Failed")

      assert has_element?(
               view,
               "[data-testid=status-message]",
               "Try restoring again, or pick an earlier backup"
             )

      assert has_element?(view, "[data-testid=backup-run][data-run-status=failed]")
    end
  end

  describe "stop backing up" do
    test "is confirmed before the row is removed", %{conn: conn, user: user, version: version} do
      instance = instance!(version, user)
      setting!(instance)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      refute has_element?(view, "[data-testid=stop-backups-confirm]")

      render_click(element(view, "[data-testid=stop-backups]"))

      assert has_element?(view, "[data-testid=stop-backups-confirm]", "Yes, stop backing up")
      assert render(view) =~ "Snapshots already in your bucket stay there"

      render_click(element(view, "[data-testid=stop-backups-confirm]"))

      assert has_element?(view, "[data-testid=backups-unconfigured]")

      assert has_element?(
               view,
               "[data-testid=backups-notice]",
               "Your snapshots stay in your bucket"
             )

      assert {:error, _missing} = BackupSetting.get_by_instance(instance.id, actor: user)
    end
  end

  describe "policies and states" do
    test "another org's instance never reaches the page", %{conn: conn, version: version} do
      other = SessionHelpers.user!()
      theirs = instance!(version, other)
      setting!(theirs)
      run!(theirs, %{status: :succeeded, snapshot_id: "6b757e02e6a7c1d8", bytes_added: 1024})

      case live(conn, ~p"/instances/#{theirs.id}") do
        {:ok, view, _html} ->
          assert_redirect(view, ~p"/instances")

        {:error, {:live_redirect, %{to: to}}} ->
          assert to == ~p"/instances"
      end
    end

    test "an org member sees the same org's panel", %{conn: conn, user: user, version: version} do
      member = SessionHelpers.user!()
      org = personal_org!(user)

      {:ok, _membership} =
        Membership.create(
          %{organization_id: org.id, user_id: member.id, role: :member},
          authorize?: false
        )

      instance = instance!(version, user)
      setting!(instance)

      member_conn = SessionHelpers.sign_in(conn, member)
      {:ok, view, _html} = live(member_conn, ~p"/instances/#{instance.id}")

      assert has_element?(view, "[data-testid=backups-panel]")
      assert has_element?(view, "[data-testid=backup-endpoint]", @s3_endpoint)
    end

    test "a lost instance says backups live with the app, not a config panel", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance)

      {:ok, lost} = InstanceK8s.update_status(instance, :lost, "Namespace gone from cluster")

      {:ok, view, html} = live(conn, ~p"/instances/#{lost.id}")

      assert has_element?(view, "[data-testid=backups-unavailable]")

      assert has_element?(
               view,
               "[data-testid=backups-unavailable]",
               "snapshots in your bucket are untouched"
             )

      refute has_element?(view, "[data-testid=back-up-now]")
      refute has_element?(view, "[data-testid=backup-endpoint]")
      refute_k8s_terms(html)
    end

    test "a pending instance offers setup only once it has a namespace", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = InstanceFixtures.instance!(version, user)
      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      refute has_element?(view, "[data-testid=backups-setup]")

      InstanceFixtures.pin!(instance, namespace: "fluxvale-app-#{instance.id}")
      render(view)

      assert has_element?(view, "[data-testid=backups-setup]")
    end

    test "the page re-reads the panel on a status broadcast", %{
      conn: conn,
      user: user,
      version: version
    } do
      instance = instance!(version, user)
      setting!(instance)

      {:ok, view, _html} = live(conn, ~p"/instances/#{instance.id}")

      run!(instance, %{status: :succeeded, snapshot_id: "6b757e02e6a7c1d8", bytes_added: 2048})

      # The sweep writes the run and nothing on the instance — this is the
      # page's own re-render path (a status tick or any broadcast).
      InstanceK8s.update_status(instance, :running, "All replicas ready")
      render(view)

      assert has_element?(view, "[data-testid=backup-run]", "6b757e02")
      assert has_element?(view, "[data-testid=backups-health]", "Healthy")
    end
  end
end
