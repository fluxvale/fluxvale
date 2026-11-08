defmodule FluxVale.Infrastructure.Operations.GrowStorageVolumeTest do
  @moduledoc """
  The online storage growth's cluster apply (#250): the storage quota and
  the `app-data` PVC at `max(row, live)`; a normal N→M grow leaves the
  Deployment alone (no pod roll), while the 0→N file-access crossing mints
  the sidecar's world and re-applies the Deployment so the WebDAV
  container exists. A cluster failure fails the action — the row and its
  audit era roll back together (the set_exposure contract).
  """

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Clients.K8s.Resources.StorageClass
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceAllocationSnapshot
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.TestSupport.InstanceFixtures

  defp stub_kubeconfig do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
  end

  defp stub_quota do
    stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
  end

  # The claim read the widening rule rides: the applied size is
  # max(row, live).
  defp stub_live_claim(gb) do
    stub(PersistentVolumeClaim, :get, fn _kc, _ns, "app-data" ->
      {:ok, %{"spec" => %{"resources" => %{"requests" => %{"storage" => "#{gb}Gi"}}}}}
    end)
  end

  defp no_claim do
    {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
  end

  defp stub_env_secret(response) do
    stub(Secret, :get, fn _kc, _ns, "app-env" -> response end)
  end

  defp no_secret do
    {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
  end

  defp user do
    User.create!("grow-op-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  # A deployed, running row (namespace pinned — cluster_managed?). The app
  # version and the instance attrs both take opts; `file_access` rides the
  # VERSION fixture — the instance snapshots it from the App's flag.
  defp running_deployed!(attrs \\ []) do
    version_attrs = Keyword.get(attrs, :version_opts, [])
    instance_attrs = Keyword.delete(attrs, :version_opts)
    version = InstanceFixtures.app_version!(version_attrs)
    InstanceFixtures.local_cluster!()

    base = %{name: "Grow op", app_version_id: version.id, env_vars: %{}}
    params = Map.merge(base, Map.new(instance_attrs))
    created = Instance.create!(params, actor: user())
    running = InstanceFixtures.walk_to!(created, :running)

    InstanceFixtures.pin!(running, namespace: "fluxvale-app-#{created.id}")
  end

  test "an N→M grow patches the PVC and the storage quota — no Deployment re-apply" do
    stub_kubeconfig()
    instance = running_deployed!(storage_gb: 10)
    ns = "fluxvale-app-#{instance.id}"

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

    expect(ResourceQuota, :create, fn _kc, ^ns, "app-quota", spec ->
      # Compute is untouched; the storage component moves.
      assert Decimal.eq?(spec.cpu, Decimal.new("0.5"))
      assert spec.memory == 256
      assert spec.storage == 20
      {:ok, %{}}
    end)

    stub_live_claim(10)

    expect(PersistentVolumeClaim, :upsert, fn _kc, ^ns, "app-data", spec ->
      assert spec.size == "20Gi"
      {:ok, %{}}
    end)

    # The pod does not roll: no deployment read/apply, no env read.
    reject(Deployment, :get, 3)
    reject(Deployment, :create, 4)
    reject(Secret, :get, 3)

    assert {:ok, grown} = Instance.grow_storage(instance, %{storage_gb: 20}, authorize?: false)
    assert grown.storage_gb == 20
  end

  test "0→N on a file-access app mints the sidecar world and re-applies the Deployment" do
    stub_kubeconfig()
    instance = running_deployed!(version_opts: [file_access: true])
    ns = "fluxvale-app-#{instance.id}"

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

    expect(ResourceQuota, :create, fn _kc, ^ns, "app-quota", spec ->
      # The updated row's 0.5 + the 0.05 sidecar request; memory 256 + 64.
      assert Decimal.eq?(spec.cpu, Decimal.new("0.55"))
      assert spec.memory == 320
      assert spec.storage == 10
      {:ok, %{}}
    end)

    expect(PersistentVolumeClaim, :get, fn _kc, ^ns, "app-data" -> no_claim() end)

    expect(PersistentVolumeClaim, :upsert, fn _kc, ^ns, "app-data", spec ->
      assert spec.size == "10Gi"
      {:ok, %{}}
    end)

    # The credential already exists — the get-or-create path returns it,
    # and no Secret.create (rotation) may fire.
    expect(Secret, :get_data, fn _kc, ^ns, "file-access" ->
      {:ok, %{"RCLONE_USER" => "owner", "RCLONE_PASS" => "configured"}}
    end)

    reject(Secret, :create, 4)

    expect(Service, :create, fn _kc, ^ns, "dav", _spec -> {:ok, %{}} end)
    stub(EdgeRoutes, :apply_serving, fn _kc, _instance -> :ok end)
    stub(EdgeRoutes, :ensure_wake_targets, fn _kc, _instance -> :ok end)

    # The crossing re-applies the Deployment at the row's footprint — env
    # posture from the cluster, replicas from the live claim.
    stub_env_secret(no_secret())

    expect(Deployment, :get, fn _kc, ^ns, "app" ->
      {:ok, %{"spec" => %{"replicas" => 1}}}
    end)

    expect(Deployment, :create, fn _kc, ^ns, "app", spec ->
      assert spec.sidecar != nil
      assert spec.replicas == 1
      assert spec.pvc_name == "app-data"
      {:ok, %{}}
    end)

    assert {:ok, grown} = Instance.grow_storage(instance, %{storage_gb: 10}, authorize?: false)
    assert grown.storage_gb == 10
  end

  test "0→N on a non-file-access instance mints only the claim — no Deployment re-apply" do
    stub_kubeconfig()
    instance = running_deployed!()
    ns = "fluxvale-app-#{instance.id}"

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)
    stub_quota()

    expect(PersistentVolumeClaim, :get, fn _kc, ^ns, "app-data" -> no_claim() end)

    expect(PersistentVolumeClaim, :upsert, fn _kc, ^ns, "app-data", spec ->
      assert spec.size == "10Gi"
      {:ok, %{}}
    end)

    reject(Secret, :get_data, 3)
    reject(Secret, :get, 3)
    reject(Service, :create, 4)
    reject(EdgeRoutes, :apply_serving, 2)
    reject(EdgeRoutes, :ensure_wake_targets, 2)
    reject(Deployment, :get, 3)
    reject(Deployment, :create, 4)

    assert {:ok, grown} = Instance.grow_storage(instance, %{storage_gb: 10}, authorize?: false)
    assert grown.storage_gb == 10
  end

  test "a failed PVC widen fails the action — the row and the era trail roll back" do
    stub_kubeconfig()
    instance = running_deployed!(storage_gb: 10)

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)
    stub_quota()
    stub_live_claim(10)

    expect(PersistentVolumeClaim, :upsert, fn _kc, _ns, "app-data", _spec ->
      {:error, Error.connection_error("pvc apply refused")}
    end)

    reject(Deployment, :get, 3)
    reject(Deployment, :create, 4)
    reject(Secret, :get, 3)

    assert {:error, _reason} =
             Instance.grow_storage(instance, %{storage_gb: 20}, authorize?: false)

    fresh = Ash.get!(Instance, instance.id, authorize?: false)
    assert fresh.storage_gb == 10

    # Era 1 still open — nothing superseded by the rolled-back growth.
    assert {:ok, [era1]} = InstanceAllocationSnapshot.in_force(instance.id, authorize?: false)
    assert era1.storage_gb == 10

    rows = Ash.read!(InstanceAllocationSnapshot, authorize?: false)
    assert length(rows) == 1
  end
end
