defmodule FluxVale.Infrastructure.Operations.DeployInstanceBackupQuotaTest do
  @moduledoc false

  # #222 (ADR-0037 §3): DeployInstance re-applies the quota with the
  # backup Job's margin when the instance has an enabled BackupSetting.
  # Split from deploy_instance_test.exs so the row-precondition setup
  # stays local (that file is already long).

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.DeployInstance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    User.create!("quota-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  # One cluster per test: ResolveCluster pins the only cluster row.
  defp deploying!(owner, version_attrs \\ %{}) do
    attrs = Map.new(version_attrs)
    version = InstanceFixtures.app_version!(attrs)

    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(
        %{name: "Quota #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: owner
      )

    {:ok, deploying} = InstanceK8s.update_status(instance, :deploying, nil)

    InstanceFixtures.pin!(deploying,
      namespace: "fluxvale-app-#{instance.id}",
      deployed_at: DateTime.utc_now()
    )
  end

  defp stub_kubeconfig do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _name, _spec -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, "wake", _spec -> {:ok, %{}} end)
  end

  defp stub_rest do
    stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Secret, :create, fn _kc, _ns, _n, _d -> {:ok, %{}} end)
    stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
  end

  defp setting!(instance, enabled) do
    BackupSetting
    |> Ash.Changeset.for_create(
      :create,
      %{
        instance_id: instance.id,
        endpoint: "https://account.r2.cloudflarestorage.com",
        bucket: "fluxvale-kavita",
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        enabled: enabled
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  describe "quota_spec/1 — the backup margin (#222)" do
    test "no BackupSetting row: the quota is the bare allocation" do
      stub_kubeconfig()
      stub_rest()
      instance = deploying!(user())
      ns = instance.namespace

      expect(ResourceQuota, :create, fn _kc, ^ns, "app-quota", spec ->
        assert spec == %{cpu: 0.5, memory: 256, storage: 0}
        {:ok, %{}}
      end)

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :starting
    end

    test "an enabled setting widens the quota by the Job's requests" do
      stub_kubeconfig()
      stub_rest()
      instance = deploying!(user())
      setting!(instance, true)
      ns = instance.namespace

      expect(ResourceQuota, :create, fn _kc, ^ns, "app-quota", spec ->
        # 0.5 / 256 allocation + 0.1 / 128 for the restic Job
        assert spec == %{cpu: Decimal.new("0.6"), memory: 384, storage: 0}
        assert Decimal.to_string(spec.cpu) == "0.6"
        {:ok, %{}}
      end)

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :starting
    end

    test "a disabled setting keeps the bare allocation (the Job won't run)" do
      stub_kubeconfig()
      stub_rest()
      instance = deploying!(user())
      setting!(instance, false)
      ns = instance.namespace

      expect(ResourceQuota, :create, fn _kc, ^ns, "app-quota", spec ->
        assert spec == %{cpu: 0.5, memory: 256, storage: 0}
        {:ok, %{}}
      end)

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :starting
    end

    test "a file-access instance stacks the sidecar margin and the backup margin" do
      stub_kubeconfig()
      stub_rest()

      stub(Secret, :get_data, fn _kc, _ns, "file-access" ->
        {:ok, %{"RCLONE_USER" => "fluxvale", "RCLONE_PASS" => "existing"}}
      end)

      instance = deploying!(user(), file_access: true, default_storage_gb: 10)
      setting!(instance, true)
      ns = instance.namespace

      expect(ResourceQuota, :create, fn _kc, ^ns, "app-quota", spec ->
        # 0.5 / 256 + 0.05 / 64 sidecar + 0.1 / 128 backup, in Decimal —
        # the sidecar branch hands a Decimal in, so the addition must not
        # round (0.65 exactly).
        assert spec == %{cpu: Decimal.new("0.65"), memory: 448, storage: 10}
        assert Decimal.to_string(spec.cpu) == "0.65"
        {:ok, %{}}
      end)

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :starting
    end
  end
end
