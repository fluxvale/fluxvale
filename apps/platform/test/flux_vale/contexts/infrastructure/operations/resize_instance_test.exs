defmodule FluxVale.Infrastructure.Operations.ResizeInstanceTest do
  @moduledoc """
  The resize action's cluster re-apply (#493): quota re-applied with
  the new allocation (+ platform margins), deployment re-applied at the
  new footprint with replicas following the live claim (0 while
  stopped; a racing start's scale-to-one preserved), and the PVC moved
  only when storage actually moved — the claim only ever widens
  (max(row, live)), so a partial-failure divergence heals instead of
  wedging. A 0→N crossing on a file-access app also mints the sidecar's
  world (credential Secret get-or-create, DAV Service, edge arms). The
  env_from_secret decision reads the cluster's app-env Secret. A
  cluster failure fails the ACTION — the row and the audit trail roll
  back together (the set_exposure contract).
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

  # The quota re-applies on every resize; tests that don't assert its
  # spec still stub it so the real client never runs. Same for the
  # deployment re-apply.
  defp stub_quota do
    stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
  end

  # The re-apply reads the live claim for replicas, then applies at it.
  defp stub_live_replicas(replicas) do
    stub(Deployment, :get, fn _kc, _ns, "app" ->
      {:ok, %{"spec" => %{"replicas" => replicas}}}
    end)
  end

  defp stub_deployment do
    stub_live_replicas(0)
    stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
  end

  # The env_from_secret decision reads the cluster's app-env Secret
  # (cluster truth, not the row's env_vars).
  defp stub_env_secret(response) do
    stub(Secret, :get, fn _kc, _ns, "app-env" -> response end)
  end

  defp secret_exists, do: {:ok, %{"KEY" => "value"}}

  defp no_secret do
    {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
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

  defp user do
    User.create!("resize-op-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp owner_of(instance) do
    org =
      instance
      |> Ash.load!(:organization, authorize?: false)
      |> Map.get(:organization)

    org
    |> Ash.load!(:members, authorize?: false)
    |> Map.get(:members)
    |> List.first()
  end

  # A deployed, stopped row (namespace pinned — cluster_managed?).
  # `file_access` (and any other blueprint attr) rides the VERSION
  # fixture via :version_opts — the instance snapshots it from the App's
  # catalog flag.
  defp stopped_deployed!(attrs \\ []) do
    version_attrs = Keyword.get(attrs, :version_opts, [])
    instance_attrs = Keyword.delete(attrs, :version_opts)
    version = InstanceFixtures.app_version!(version_attrs)
    InstanceFixtures.local_cluster!()

    base = %{name: "Resize op", app_version_id: version.id, env_vars: %{}}
    params = Map.merge(base, Map.new(instance_attrs))
    created = Instance.create!(params, actor: user())
    stopped = InstanceFixtures.walk_to!(created, :stopped)

    InstanceFixtures.pin!(stopped, namespace: "fluxvale-app-#{created.id}")
  end

  test "quota and deployment re-apply with the new allocation; replicas stay at the live 0" do
    stub_kubeconfig()
    stub_quota()
    stub_env_secret(no_secret())
    instance = stopped_deployed!()
    owner = owner_of(instance)
    ns = "fluxvale-app-#{instance.id}"

    expect(ResourceQuota, :create, fn _kc, ^ns, "app-quota", spec ->
      assert Decimal.eq?(spec.cpu, Decimal.new("2"))
      assert spec.memory == 1024
      assert spec.storage == 0
      {:ok, %{}}
    end)

    # The live claim read: stopped-first means the claim is at 0.
    expect(Deployment, :get, fn _kc, ^ns, "app" ->
      {:ok, %{"spec" => %{"replicas" => 0}}}
    end)

    expect(Deployment, :create, fn _kc, ^ns, "app", spec ->
      assert spec.image == "registry.example.com/app:1.0"
      assert spec.port == 3000
      # Decimal (#612): the re-apply may carve backing shares out of a
      # fresh allocation — float would round.
      assert Decimal.eq?(spec.cpu, Decimal.new("2"))
      assert spec.memory == 1024
      assert spec.replicas == 0
      # No app-env Secret on the cluster — no envFrom reference.
      assert spec.env_from_secret == nil
      {:ok, %{}}
    end)

    stub_live_claim(0)
    reject(PersistentVolumeClaim, :upsert, 4)

    assert {:ok, resized} =
             Instance.resize(
               instance,
               %{cpu_cores: Decimal.new("2"), memory_mb: 1024},
               actor: owner
             )

    assert Decimal.eq?(resized.cpu_cores, Decimal.new("2"))
  end

  test "a racing start's scale-to-one survives the re-apply (live 1 applies at 1)" do
    stub_kubeconfig()
    stub_quota()
    stub_env_secret(no_secret())
    instance = stopped_deployed!()
    owner = owner_of(instance)

    # The race's honest outcome: start scaled the Deployment to 1
    # before the row landed :starting — the re-apply carries the 1.
    expect(Deployment, :get, fn _kc, _ns, "app" ->
      {:ok, %{"spec" => %{"replicas" => 1}}}
    end)

    expect(Deployment, :create, fn _kc, _ns, "app", spec ->
      assert spec.replicas == 1
      {:ok, %{}}
    end)

    assert {:ok, _resized} = Instance.resize(instance, %{memory_mb: 512}, actor: owner)
  end

  test "an app whose deploy seeded URL env keeps env_from_secret — cluster truth, not the row" do
    stub_kubeconfig()
    stub_quota()
    stub_deployment()
    # Empty env_vars, but deploy's URL seeding created the Secret: the
    # pod references it, so the re-apply must keep envFrom — a recompute
    # from the row would strip it.
    stub_env_secret(secret_exists())

    instance =
      stopped_deployed!(
        version_opts: [instance_url_env: "APP_ROOT_URL"],
        env_vars: %{}
      )

    owner = owner_of(instance)

    expect(Deployment, :create, fn _kc, _ns, "app", spec ->
      assert spec.env_from_secret == "app-env"
      {:ok, %{}}
    end)

    assert {:ok, _resized} = Instance.resize(instance, %{memory_mb: 512}, actor: owner)
  end

  test "an app with truly empty env (no Secret) gets no envFrom" do
    stub_kubeconfig()
    stub_quota()
    stub_deployment()
    stub_env_secret(no_secret())

    instance = stopped_deployed!(env_vars: %{})
    owner = owner_of(instance)

    expect(Deployment, :create, fn _kc, _ns, "app", spec ->
      assert spec.env_from_secret == nil
      {:ok, %{}}
    end)

    assert {:ok, _resized} = Instance.resize(instance, %{memory_mb: 512}, actor: owner)
  end

  # The never-deployed shape: no live claim at all (404) — the
  # stopped-first 0 is the floor.
  test "a 404 deployment read applies at the stopped-first 0" do
    stub_kubeconfig()
    stub_quota()
    stub_env_secret(no_secret())

    instance = stopped_deployed!()
    owner = owner_of(instance)

    expect(Deployment, :get, fn _kc, _ns, "app" ->
      {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
    end)

    expect(Deployment, :create, fn _kc, _ns, "app", spec ->
      assert spec.replicas == 0
      {:ok, %{}}
    end)

    assert {:ok, _resized} = Instance.resize(instance, %{memory_mb: 512}, actor: owner)
  end

  # A manifest without spec.replicas (not a shape the API server
  # produces) reads as 0 — defensive, never a crash.
  test "a manifest without spec.replicas reads as 0" do
    stub_kubeconfig()
    stub_quota()
    stub_env_secret(no_secret())

    instance = stopped_deployed!()
    owner = owner_of(instance)

    expect(Deployment, :get, fn _kc, _ns, "app" -> {:ok, %{}} end)

    expect(Deployment, :create, fn _kc, _ns, "app", spec ->
      assert spec.replicas == 0
      {:ok, %{}}
    end)

    assert {:ok, _resized} = Instance.resize(instance, %{memory_mb: 512}, actor: owner)
  end

  test "a failed deployment read fails the resize — never guess the replica posture" do
    stub_kubeconfig()
    stub_quota()
    stub_env_secret(no_secret())

    instance = stopped_deployed!()
    owner = owner_of(instance)

    stub(Deployment, :get, fn _kc, _ns, "app" ->
      {:error, Error.connection_error("api server on fire")}
    end)

    assert {:error, _reason} = Instance.resize(instance, %{memory_mb: 512}, actor: owner)

    fresh = Ash.get!(Instance, instance.id, authorize?: false)
    assert fresh.memory_mb == instance.memory_mb
  end

  test "a failed env-Secret read fails the resize — never guess the env posture" do
    stub_kubeconfig()
    stub_quota()
    stub_deployment()
    stub_env_secret({:error, Error.connection_error("api server on fire")})

    instance = stopped_deployed!()
    owner = owner_of(instance)

    assert {:error, _reason} = Instance.resize(instance, %{memory_mb: 512}, actor: owner)

    fresh = Ash.get!(Instance, instance.id, authorize?: false)
    assert fresh.memory_mb == instance.memory_mb
  end

  test "a file-access instance's quota widens by the sidecar margin" do
    stub_kubeconfig()
    stub_deployment()
    stub_env_secret(no_secret())

    instance =
      stopped_deployed!(version_opts: [file_access: true], storage_gb: 10)

    owner = owner_of(instance)

    expect(ResourceQuota, :create, fn _kc, _ns, "app-quota", spec ->
      # The UPDATED row's 0.5 + the 0.05 sidecar request; memory 512 + 64.
      assert Decimal.eq?(spec.cpu, Decimal.new("0.55"))
      assert spec.memory == 576
      assert spec.storage == 10
      {:ok, %{}}
    end)

    assert {:ok, _resized} = Instance.resize(instance, %{memory_mb: 512}, actor: owner)
  end

  test "a grow upserts the PVC wider (capability-gated)" do
    stub_kubeconfig()
    stub_quota()
    stub_deployment()
    stub_env_secret(no_secret())
    instance = stopped_deployed!(storage_gb: 10)
    owner = owner_of(instance)
    ns = "fluxvale-app-#{instance.id}"

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)
    stub_live_claim(10)

    expect(PersistentVolumeClaim, :upsert, fn _kc, ^ns, "app-data", spec ->
      assert spec.size == "20Gi"
      {:ok, %{}}
    end)

    assert {:ok, resized} = Instance.resize(instance, %{storage_gb: 20}, actor: owner)
    assert resized.storage_gb == 20
  end

  test "0→N storage mints the claim at the row's size" do
    stub_kubeconfig()
    stub_quota()
    stub_deployment()
    stub_env_secret(no_secret())
    instance = stopped_deployed!()
    owner = owner_of(instance)
    ns = "fluxvale-app-#{instance.id}"

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

    # No live claim (404): the row's size is the floor.
    expect(PersistentVolumeClaim, :get, fn _kc, ^ns, "app-data" -> no_claim() end)

    expect(PersistentVolumeClaim, :upsert, fn _kc, ^ns, "app-data", spec ->
      assert spec.size == "10Gi"
      {:ok, %{}}
    end)

    assert {:ok, resized} = Instance.resize(instance, %{storage_gb: 10}, actor: owner)
    assert resized.storage_gb == 10
  end

  # A "0Gi" claim reads as no claim — the row's size is the floor.
  test "a zero-GB live claim applies at the row's size" do
    stub_kubeconfig()
    stub_quota()
    stub_deployment()
    stub_env_secret(no_secret())
    instance = stopped_deployed!()
    owner = owner_of(instance)

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)
    stub_live_claim(0)

    expect(PersistentVolumeClaim, :upsert, fn _kc, _ns, "app-data", spec ->
      assert spec.size == "15Gi"
      {:ok, %{}}
    end)

    assert {:ok, resized} = Instance.resize(instance, %{storage_gb: 15}, actor: owner)
    assert resized.storage_gb == 15
  end

  # The partial-failure wedge: row rolled back (target 15), live claim
  # already 20 — the re-apply lands max(15, 20) = 20Gi, never a shrink.
  test "a live claim wider than the row target widens to the LIVE size, not the row's" do
    stub_kubeconfig()
    stub_quota()
    stub_deployment()
    stub_env_secret(no_secret())
    instance = stopped_deployed!()
    owner = owner_of(instance)
    ns = "fluxvale-app-#{instance.id}"

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)
    stub_live_claim(20)

    expect(PersistentVolumeClaim, :upsert, fn _kc, ^ns, "app-data", spec ->
      assert spec.size == "20Gi"
      {:ok, %{}}
    end)

    assert {:ok, resized} = Instance.resize(instance, %{storage_gb: 15}, actor: owner)
    assert resized.storage_gb == 15
  end

  # The convergence path: a first resize to 20 lost its Deployment
  # apply (the claim landed, the row rolled back); the retry converges —
  # the claim re-applies at max(20, live 20) and the deployment lands.
  test "a retry after a failed operand converges past the widened claim" do
    stub_kubeconfig()
    stub_quota()
    stub_env_secret(no_secret())
    instance = stopped_deployed!()
    owner = owner_of(instance)

    # The probe caches per cluster — one live probe serves both passes.
    stub(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)
    stub_live_claim(20)
    stub_live_replicas(0)

    # First pass: the claim lands (20Gi), the deployment fails, the row
    # rolls back.
    expect(PersistentVolumeClaim, :upsert, fn _kc, _ns, "app-data", spec ->
      assert spec.size == "20Gi"
      {:ok, %{}}
    end)

    expect(Deployment, :create, fn _kc, _ns, "app", _spec ->
      {:error, Error.connection_error("cluster on fire")}
    end)

    assert {:error, _reason} = Instance.resize(instance, %{storage_gb: 20}, actor: owner)

    # The row rolled back (still 0); the retry targets 20 — the live
    # claim is already there, and the re-apply is an idempotent 20Gi.
    expect(Deployment, :create, fn _kc, _ns, "app", spec ->
      assert spec.replicas == 0
      {:ok, %{}}
    end)

    expect(PersistentVolumeClaim, :upsert, fn _kc, _ns, "app-data", spec ->
      assert spec.size == "20Gi"
      {:ok, %{}}
    end)

    assert {:ok, resized} = Instance.resize(instance, %{storage_gb: 20}, actor: owner)
    assert resized.storage_gb == 20
  end

  test "an unparseable live claim fails the resize — never risk shrinking a live claim" do
    stub_kubeconfig()
    stub_quota()
    stub_deployment()
    stub_env_secret(no_secret())
    instance = stopped_deployed!()
    owner = owner_of(instance)

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

    stub(PersistentVolumeClaim, :get, fn _kc, _ns, "app-data" ->
      {:ok, %{"spec" => %{"resources" => %{"requests" => %{"storage" => "garbage"}}}}}
    end)

    assert {:error, _reason} = Instance.resize(instance, %{storage_gb: 10}, actor: owner)

    fresh = Ash.get!(Instance, instance.id, authorize?: false)
    assert fresh.storage_gb == 0
  end

  # Finding A: the crossing gains the sidecar, whose world a deploy at
  # gb=0 never minted — credential Secret (get-or-create: the get-data
  # path must NOT rotate an existing credential), DAV Service, edge arms.
  test "0→N on a file-access app mints the sidecar world — without rotating an existing credential" do
    stub_kubeconfig()
    stub_quota()
    stub_deployment()
    stub_env_secret(no_secret())

    instance =
      stopped_deployed!(version_opts: [file_access: true], env_vars: %{})

    owner = owner_of(instance)
    ns = "fluxvale-app-#{instance.id}"

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)
    expect(PersistentVolumeClaim, :get, fn _kc, ^ns, "app-data" -> no_claim() end)

    expect(PersistentVolumeClaim, :upsert, fn _kc, ^ns, "app-data", _spec -> {:ok, %{}} end)

    # The credential already exists — the get-data path returns it, and
    # no Secret.create (rotation) may fire.
    expect(Secret, :get_data, fn _kc, ^ns, "file-access" ->
      {:ok, %{"RCLONE_USER" => "owner", "RCLONE_PASS" => "configured"}}
    end)

    reject(Secret, :create, 4)

    expect(Service, :create, fn _kc, ^ns, "dav", _spec -> {:ok, %{}} end)
    stub(EdgeRoutes, :apply_serving, fn _kc, _instance -> :ok end)
    stub(EdgeRoutes, :ensure_wake_targets, fn _kc, _instance -> :ok end)

    assert {:ok, resized} = Instance.resize(instance, %{storage_gb: 10}, actor: owner)
    assert resized.storage_gb == 10
  end

  test "a resize with storage already > 0 (file-access) mints none of the sidecar world" do
    stub_kubeconfig()
    stub_quota()
    stub_deployment()
    stub_env_secret(no_secret())

    instance =
      stopped_deployed!(version_opts: [file_access: true], storage_gb: 10)

    owner = owner_of(instance)

    # No crossing → no mint of secret, dav service, or edge arms.
    reject(Secret, :get_data, 3)
    reject(Service, :create, 4)
    reject(EdgeRoutes, :apply_serving, 2)
    reject(PersistentVolumeClaim, :get, 3)
    reject(PersistentVolumeClaim, :upsert, 4)

    assert {:ok, _resized} = Instance.resize(instance, %{memory_mb: 512}, actor: owner)
  end

  test "0→N on a non-file-access instance mints only the claim" do
    stub_kubeconfig()
    stub_quota()
    stub_deployment()
    stub_env_secret(no_secret())

    instance = stopped_deployed!()
    owner = owner_of(instance)
    ns = "fluxvale-app-#{instance.id}"

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)
    expect(PersistentVolumeClaim, :get, fn _kc, ^ns, "app-data" -> no_claim() end)

    expect(PersistentVolumeClaim, :upsert, fn _kc, ^ns, "app-data", _spec -> {:ok, %{}} end)

    reject(Secret, :get_data, 3)
    reject(Service, :create, 4)
    reject(EdgeRoutes, :apply_serving, 2)

    assert {:ok, resized} = Instance.resize(instance, %{storage_gb: 10}, actor: owner)
    assert resized.storage_gb == 10
  end

  test "a failed PVC widen fails the action — the row rolls back" do
    stub_kubeconfig()
    stub_quota()
    stub_deployment()
    stub_env_secret(no_secret())
    instance = stopped_deployed!(storage_gb: 10)
    owner = owner_of(instance)

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)
    stub_live_claim(10)

    expect(PersistentVolumeClaim, :upsert, fn _kc, _ns, "app-data", _spec ->
      {:error, Error.connection_error("pvc apply refused")}
    end)

    assert {:error, _reason} = Instance.resize(instance, %{storage_gb: 20}, actor: owner)

    fresh = Ash.get!(Instance, instance.id, authorize?: false)
    assert fresh.storage_gb == 10
  end

  test "a failed PVC read fails the action — never guess the live claim" do
    stub_kubeconfig()
    stub_quota()
    stub_deployment()
    stub_env_secret(no_secret())
    instance = stopped_deployed!(storage_gb: 10)
    owner = owner_of(instance)

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

    stub(PersistentVolumeClaim, :get, fn _kc, _ns, "app-data" ->
      {:error, Error.connection_error("api server on fire")}
    end)

    assert {:error, _reason} = Instance.resize(instance, %{storage_gb: 20}, actor: owner)

    fresh = Ash.get!(Instance, instance.id, authorize?: false)
    assert fresh.storage_gb == 10
  end

  test "a cluster failure fails the action — the row and the trail roll back" do
    stub_kubeconfig()
    stub_quota()
    stub_env_secret(no_secret())
    stub_live_replicas(0)
    instance = stopped_deployed!(storage_gb: 10)
    owner = owner_of(instance)

    expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)
    stub_live_claim(10)

    expect(PersistentVolumeClaim, :upsert, fn _kc, _ns, "app-data", _spec -> {:ok, %{}} end)

    expect(Deployment, :create, fn _kc, _ns, "app", _spec ->
      {:error, Error.connection_error("cluster on fire")}
    end)

    assert {:error, _reason} =
             Instance.resize(
               instance,
               %{cpu_cores: Decimal.new("2"), storage_gb: 20},
               actor: owner
             )

    fresh = Ash.get!(Instance, instance.id, authorize?: false)
    assert Decimal.eq?(fresh.cpu_cores, instance.cpu_cores)
    assert fresh.storage_gb == 10

    # The settled interval and the audit append rolled back with it:
    # era 1 still open, nothing superseded.
    assert {:ok, [_era1]} =
             InstanceAllocationSnapshot.in_force(instance.id, authorize?: false)

    rows = Ash.read!(InstanceAllocationSnapshot, authorize?: false)
    assert length(rows) == 1
  end

  # #612 (ADR-0045 §4.7): resize re-applies at the new footprint — the
  # app request is RECARVED (new allocation − shares) while the DB
  # requests stay constant, and the backing-services Secret is never
  # touched (the envFrom witness is app-env, which already carries the
  # URL — resize keeps it for free).
  test "a backing-services instance re-carves the app request; DB shares constant, no secret touch" do
    stub_kubeconfig()
    stub_env_secret(secret_exists())

    version = InstanceFixtures.backing_version!()
    InstanceFixtures.local_cluster!()

    created =
      Instance.create!(
        %{name: "Backing resize", app_version_id: version.id, env_vars: %{}},
        actor: user()
      )

    stopped = InstanceFixtures.walk_to!(created, :stopped)
    instance = InstanceFixtures.pin!(stopped, namespace: "fluxvale-app-#{created.id}")
    owner = owner_of(instance)

    expect(ResourceQuota, :create, fn _kc, _ns, "app-quota", spec ->
      # Quota stays the bare NEW allocation — the shares are inside it.
      assert Decimal.eq?(spec.cpu, Decimal.new("2"))
      assert spec.memory == 2048
      {:ok, %{}}
    end)

    expect(Deployment, :get, fn _kc, _ns, "app" ->
      {:ok, %{"spec" => %{"replicas" => 0}}}
    end)

    expect(Deployment, :create, fn _kc, _ns, "app", spec ->
      # Recarved at the new allocation: 2.0 − 0.15 = 1.85 CPU,
      # 2048 − 320 = 1728 MB; the DB specs ride unchanged from the
      # create-time snapshot.
      assert Decimal.eq?(spec.cpu, Decimal.new("1.85"))
      assert spec.memory == 1728

      [pg, redis] = spec.backing_services
      assert Decimal.eq?(pg.cpu, Decimal.new("0.10")) and pg.memory_mb == 256
      assert Decimal.eq?(redis.cpu, Decimal.new("0.05")) and redis.memory_mb == 64
      {:ok, %{}}
    end)

    stub_live_claim(10)

    # The backing Secret is deploy-owned (get-or-create at first
    # deploy): a resize neither reads nor writes it.
    reject(Secret, :get_data, 3)

    assert {:ok, resized} =
             Instance.resize(
               instance,
               %{cpu_cores: Decimal.new("2"), memory_mb: 2048},
               actor: owner
             )

    assert Decimal.eq?(resized.cpu_cores, Decimal.new("2"))
  end
end
