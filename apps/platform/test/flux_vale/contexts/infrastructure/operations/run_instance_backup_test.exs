defmodule FluxVale.Infrastructure.Operations.RunInstanceBackupTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.BackupJob
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  defp user do
    User.create!("run-backup-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp base! do
    version = InstanceFixtures.app_version!(default_storage_gb: 10)
    InstanceFixtures.local_cluster!()
    version
  end

  defp instance!(version, owner) do
    instance =
      Instance.create!(
        %{name: "Backed #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: owner
      )

    InstanceFixtures.pin!(instance, namespace: "fluxvale-app-#{instance.id}")
  end

  # The settings row is ConfigureBackups' output; here it is a precondition
  # built through the action (the repo's test-data stance).
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

  defp run!(instance, status) do
    BackupRun
    |> Ash.Changeset.for_create(
      :create,
      %{
        instance_id: instance.id,
        kind: :scheduled,
        status: status,
        started_at: DateTime.utc_now()
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp stub_k8s do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)
    stub(BackupJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
  end

  defp runs(instance) do
    BackupRun
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read!(authorize?: false)
  end

  describe "call/2 — the happy path" do
    test "creates the run, replaces the Job, and lands :running" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)
      setting = setting!(instance, %{retention_keep: 14})

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      expect(BackupJob, :delete, fn _kc, ns ->
        assert ns == instance.namespace
        {:error, %Error{reason: :not_found}}
      end)

      expect(BackupJob, :create, fn _kc, ns, spec ->
        assert ns == instance.namespace

        assert spec == %{
                 slug: instance.slug,
                 mount_path: instance.storage_mount_path,
                 keep_last: setting.retention_keep
               }

        {:ok, %{}}
      end)

      assert {:ok, run} = Infrastructure.run_instance_backup(instance, :manual)
      assert run.status == :running
      assert run.kind == :manual
      assert run.instance_id == instance.id
      assert run.started_at != nil
      assert run.finished_at == nil
    end

    test "the scheduled kind takes the same path" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)
      setting!(instance)

      stub_k8s()

      assert {:ok, run} = Infrastructure.run_instance_backup(instance, :scheduled)
      assert run.kind == :scheduled
      assert length(runs(instance)) == 1
    end

    test "a leftover Job is deleted before the apply (Jobs are immutable)" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)
      setting!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      expect(BackupJob, :delete, fn _kc, _ns -> :ok end)

      expect(BackupJob, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)

      assert {:ok, _run} = Infrastructure.run_instance_backup(instance, :manual)
    end
  end

  describe "call/2 — guards" do
    test "no settings row: :no_settings, no row, no cluster write" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)

      reject(BackupJob, :create, 3)

      assert {:error, :no_settings} = Infrastructure.run_instance_backup(instance, :manual)
      assert runs(instance) == []
    end

    test "a disabled setting: :backups_disabled, even for a manual run" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)
      setting!(instance, %{enabled: false})

      reject(BackupJob, :create, 3)

      assert {:error, :backups_disabled} = Infrastructure.run_instance_backup(instance, :manual)
      assert runs(instance) == []
    end

    test "a pending run blocks a second one" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)
      setting!(instance)
      run!(instance, :pending)

      # The one-active-run refusal is the partial unique index's
      # rejection (translated), so the op reaches its kubeconfig leg
      # before the insert refuses — stub the resolver the siblings
      # stub; the Job create stays rejected.
      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      reject(BackupJob, :create, 3)

      assert {:error, :run_in_flight} = Infrastructure.run_instance_backup(instance, :manual)
      assert length(runs(instance)) == 1
    end

    test "a running run blocks a second one" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)
      setting!(instance)
      run!(instance, :running)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      reject(BackupJob, :create, 3)

      assert {:error, :run_in_flight} = Infrastructure.run_instance_backup(instance, :manual)
    end

    test "a settled run does not block" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)
      setting!(instance)
      run!(instance, :succeeded)

      stub_k8s()

      assert {:ok, _run} = Infrastructure.run_instance_backup(instance, :manual)
      assert length(runs(instance)) == 2
    end

    test "a never-deployed instance: :not_deployed, no row" do
      version = base!()
      owner = user()

      instance =
        Instance.create!(
          %{name: "Undeployed", app_version_id: version.id, env_vars: %{}},
          actor: owner
        )

      setting!(instance)

      reject(BackupJob, :create, 3)

      assert {:error, :not_deployed} = Infrastructure.run_instance_backup(instance, :manual)
      assert runs(instance) == []
    end

    test "another instance's run never blocks this one" do
      version = base!()
      owner = user()
      mine = instance!(version, owner)
      theirs = instance!(version, owner)
      setting!(mine)
      run!(theirs, :running)

      stub_k8s()

      assert {:ok, _run} = Infrastructure.run_instance_backup(mine, :manual)
    end
  end

  describe "call/2 — cluster failures" do
    test "a kubeconfig failure writes no row" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)
      setting!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:error, Error.connection_error("no SA files")} end)

      reject(BackupJob, :create, 3)

      assert {:error, %Error{reason: :connection_error}} =
               Infrastructure.run_instance_backup(instance, :manual)

      assert runs(instance) == []
    end

    test "a failed apply settles the row :failed with the reason — no stale slot" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)
      setting!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
      stub(BackupJob, :delete, fn _kc, _ns -> {:error, %Error{reason: :not_found}} end)

      expect(BackupJob, :create, fn _kc, _ns, _spec ->
        {:error, Error.connection_error("apply rejected")}
      end)

      assert {:error, %Error{reason: :connection_error}} =
               Infrastructure.run_instance_backup(instance, :manual)

      assert [run] = runs(instance)
      assert run.status == :failed
      assert run.error_summary =~ "apply rejected"
      assert run.finished_at != nil
    end

    test "a failed leftover-Job delete fails before the apply" do
      version = base!()
      owner = user()
      instance = instance!(version, owner)
      setting!(instance)

      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      expect(BackupJob, :delete, fn _kc, _ns ->
        {:error, Error.connection_error("delete boom")}
      end)

      reject(BackupJob, :create, 3)

      assert {:error, %Error{reason: :connection_error}} =
               Infrastructure.run_instance_backup(instance, :manual)

      assert [run] = runs(instance)
      assert run.status == :failed
    end
  end
end
