defmodule FluxVale.Infrastructure.Operations.DeployInstanceTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
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
  alias FluxVale.Clients.K8s.SelfAccessReview
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.DeployInstance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    User.create!("deployer-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp deploying!(attrs \\ %{}) do
    attrs = Map.new(attrs)
    create_env = Map.get(attrs, :env, %{"FORGEJO__mailer__SMTP_PORT" => "2525"})

    blueprint = %{
      image: "codeberg.org/forgejo/forgejo:16.0.5",
      port: 3000,
      healthcheck_path: "/api/healthz",
      instance_url_env: "FORGEJO__server__ROOT_URL",
      default_cpu_cores: Decimal.new("0.5"),
      default_memory_mb: 512,
      default_storage_gb: 10,
      default_env_vars: %{"FORGEJO__security__INSTALL_LOCK" => "true"}
    }

    overrides = Map.drop(attrs, [:env])

    version =
      blueprint
      |> Map.merge(overrides)
      |> InstanceFixtures.app_version!()

    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(
        %{
          name: "My Forgejo",
          app_version_id: version.id,
          env_vars: create_env
        },
        actor: user()
      )

    {:ok, deploying} = InstanceK8s.update_status(instance, :deploying, nil)

    InstanceFixtures.pin!(deploying,
      namespace: "fluxvale-app-#{instance.id}",
      deployed_at: DateTime.utc_now()
    )
  end

  defp stub_kubeconfig do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    # #203: every deploy applies the activity-beacon and (dormant)
    # wake-marker Middlewares plus the wake ExternalName Service via
    # EdgeRoutes — default stubs, expect-ed where a test cares.
    stub(Middleware, :create, fn _kc, _ns, _name, _spec -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, "wake", _spec -> {:ok, %{}} end)
  end

  describe "call/1" do
    test "applies every namespace resource with the instance's blueprint" do
      stub_kubeconfig()
      instance = deploying!()
      ns = "fluxvale-app-#{instance.id}"

      # #196: the namespace carries this platform's env label — the
      # orphan sweep's ownership scope on the shared box.
      expect(Namespace, :create, fn _kc, ^ns, spec ->
        assert spec == %{labels: %{"fluxvale.io/platform-env" => "local"}}
        {:ok, %{}}
      end)

      expect(RoleBinding, :create, fn _kc, ^ns, "fluxvale-platform", spec ->
        assert spec == %{
                 service_account: "fluxvale-platform",
                 service_account_namespace: "fluxvale-dev",
                 role: "fluxvale-platform-workload"
               }

        {:ok, %{}}
      end)

      expect(ResourceQuota, :create, fn _kc, ^ns, "app-quota", spec ->
        # Decimal end to end (#222 F9): no float on the plain path — a
        # float round-trip can land below the pod's exact request.
        assert spec == %{cpu: Decimal.new("0.5"), memory: 512, storage: 10}
        {:ok, %{}}
      end)

      expect(NetworkPolicy, :create, fn _kc, ^ns, "default-deny-ingress", spec ->
        assert spec == %{ingress_from_namespaces: ["traefik"]}
        {:ok, %{}}
      end)

      expect(PersistentVolumeClaim, :create, fn _kc, ^ns, "app-data", spec ->
        assert spec == %{size: "10Gi"}
        {:ok, %{}}
      end)

      expect(Secret, :create, fn _kc, ^ns, "app-env", data ->
        assert data["FORGEJO__security__INSTALL_LOCK"] == "true"
        assert data["FORGEJO__mailer__SMTP_PORT"] == "2525"
        # instance_url_env is filled with the instance's public URL
        assert data["FORGEJO__server__ROOT_URL"] == "https://#{instance.slug}.fluxvale.lvh.me/"
        {:ok, %{}}
      end)

      expect(Deployment, :create, fn _kc, ^ns, "app", spec ->
        assert spec.image == "codeberg.org/forgejo/forgejo:16.0.5"
        assert spec.port == 3000
        assert spec.cpu == 0.5
        assert spec.memory == 512
        assert spec.probe_path == "/api/healthz"
        assert spec.storage_mount == "/data"
        assert spec.pvc_name == "app-data"
        assert spec.env_from_secret == "app-env"
        {:ok, %{}}
      end)

      expect(Service, :create, fn _kc, ^ns, "app", spec ->
        assert spec == %{
                 port: 80,
                 target_port: 3000,
                 selector: %{"app.kubernetes.io/name" => "app"}
               }

        {:ok, %{}}
      end)

      expect(Ingress, :create, fn _kc, ^ns, "app-ingress", spec ->
        assert spec.subdomain == instance.slug
        assert spec.service_name == "app"
        assert spec.service_port == 80
        assert spec.tls == true
        assert spec.domain == "fluxvale.lvh.me"
        {:ok, %{}}
      end)

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :starting
      assert updated.namespace == ns
      assert updated.status_message =~ "awaiting readiness"
    end

    # #265: a private deploy never reaches the public edge — no route
    # (nor beacon/wake middleware: nothing can route to either), and
    # the policy denies edge ingress from the first pod. Everything
    # else is the ordinary blueprint: the namespace still lands, the
    # workload still runs, panel/sweep/backup paths still apply.
    test "a private instance deploys with no public route and an edge-denied policy" do
      stub_kubeconfig()
      instance = deploying!()
      ns = "fluxvale-app-#{instance.id}"

      private = InstanceFixtures.pin!(instance, exposure: :private)

      stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
      stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Secret, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      # PR #267 review round 2 (P3): private rows get NO public URL in
      # their env — a dead ROOT_URL would seed the app with dead links
      # of its own. The env lands on the first deploy that finds the
      # row public.
      expect(Secret, :create, fn _kc, ^ns, "app-env", data ->
        refute Map.has_key?(data, "FORGEJO__server__ROOT_URL")
        {:ok, %{}}
      end)

      expect(Service, :create, fn _kc, ^ns, "app", _spec -> {:ok, %{}} end)

      expect(NetworkPolicy, :create, fn _kc, ^ns, "default-deny-ingress", spec ->
        assert spec == %{ingress_from_namespaces: []}
        {:ok, %{}}
      end)

      # No route, no beacon, no wake target: private is the absence of
      # an edge presence. Reaching for any of them fails the test.
      reject(Ingress, :create, 4)
      reject(Middleware, :create, 4)

      stub(Ingress, :delete, fn _kc, _ns, _name ->
        # Fresh namespace: no route exists — already the posture.
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      stub(Service, :create, fn
        _kc, _ns, "app", _spec -> {:ok, %{}}
        _kc, _ns, "wake", _spec -> flunk("private deploys mint no wake target")
      end)

      assert {:ok, updated} = DeployInstance.call(private)
      assert updated.status == :starting
    end

    test "storage-less instances skip the PVC; env-less ones skip the Secret" do
      stub_kubeconfig()

      instance =
        deploying!(default_storage_gb: 0, default_env_vars: %{}, instance_url_env: nil, env: %{})

      ns = "fluxvale-app-#{instance.id}"
      expect(Namespace, :create, fn _kc, ^ns, _spec -> {:ok, %{}} end)
      stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      reject(PersistentVolumeClaim, :create, 4)
      reject(Secret, :create, 4)

      expect(Deployment, :create, fn _kc, _ns, "app", spec ->
        assert spec.storage_mount == nil
        assert spec.pvc_name == nil
        assert spec.env_from_secret == nil
        {:ok, %{}}
      end)

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :starting
    end
  end

  describe "call/1 — #190 file access (ADR-0035)" do
    @describetag :file_access

    test "a file-access instance gets the credential Secret, sidecar, dav Service and route" do
      stub_kubeconfig()
      instance = deploying!(file_access: true)
      ns = "fluxvale-app-#{instance.id}"

      expect(Namespace, :create, fn _kc, ^ns, _spec -> {:ok, %{}} end)
      stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      # Quota widens by exactly the sidecar's requests (platform
      # overhead, not purchased allocation): 0.5/512 → 0.55/576.
      # Decimal, not float — 0.35+0.05-style sums must not round down
      # below the pod's exact request sum (review finding).
      expect(ResourceQuota, :create, fn _kc, ^ns, "app-quota", spec ->
        assert spec == %{cpu: Decimal.new("0.55"), memory: 576, storage: 10}
        assert Decimal.to_string(spec.cpu) == "0.55"
        {:ok, %{}}
      end)

      expect(Secret, :create, fn _kc, ^ns, "app-env", _data -> {:ok, %{}} end)

      # First deploy: no credential yet — get-or-create generates one.
      expect(Secret, :get_data, fn _kc, ^ns, "file-access" ->
        {:error, %K8s.Error{reason: :not_found}}
      end)

      expect(Secret, :create, fn _kc, ^ns, "file-access", data ->
        assert data["RCLONE_USER"] == "fluxvale"
        # 32 bytes CSPRNG, URL-safe base64: 43 chars, no padding
        assert Regex.match?(~r/^[A-Za-z0-9_-]{43}$/, data["RCLONE_PASS"])
        {:ok, %{}}
      end)

      expect(Deployment, :create, fn _kc, ^ns, "app", spec ->
        sidecar = spec.sidecar
        assert sidecar.image == "rclone/rclone:1.75.2"
        assert sidecar.port == 8080

        assert sidecar.args == [
                 "serve",
                 "webdav",
                 "/data",
                 "--addr",
                 "0.0.0.0:8080",
                 "--baseurl",
                 "/dav"
               ]

        assert sidecar.env_from_secret == "file-access"
        assert sidecar.storage_mount == "/data"
        assert sidecar.cpu == Decimal.new("0.05")
        assert sidecar.memory == 64
        {:ok, %{}}
      end)

      expect(Service, :create, fn _kc, ^ns, "app", _spec -> {:ok, %{}} end)
      expect(Ingress, :create, fn _kc, ^ns, "app-ingress", _spec -> {:ok, %{}} end)

      expect(Service, :create, fn _kc, ^ns, "dav", spec ->
        assert spec == %{
                 port: 80,
                 target_port: 8080,
                 selector: %{"app.kubernetes.io/name" => "app"}
               }

        {:ok, %{}}
      end)

      expect(Ingress, :create, fn _kc, ^ns, "app-dav", spec ->
        assert spec.subdomain == instance.slug
        assert spec.service_name == "dav"
        assert spec.service_port == 80
        assert spec.tls == true
        assert spec.domain == "fluxvale.lvh.me"
        assert spec.path_prefix == "/dav"
        {:ok, %{}}
      end)

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :starting
    end

    test "a Kavita-shaped mount path serves the app's own volume layout (#189 × #190)" do
      stub_kubeconfig()

      instance = deploying!(file_access: true, storage_mount_path: "/kavita/config")

      stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
      stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Secret, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      expect(Secret, :get_data, fn _kc, _ns, "file-access" ->
        {:ok, %{"RCLONE_USER" => "fluxvale", "RCLONE_PASS" => "existing"}}
      end)

      expect(Deployment, :create, fn _kc, _ns, "app", spec ->
        sidecar = spec.sidecar

        assert sidecar.args == [
                 "serve",
                 "webdav",
                 "/kavita/config",
                 "--addr",
                 "0.0.0.0:8080",
                 "--baseurl",
                 "/dav"
               ]

        assert sidecar.storage_mount == "/kavita/config"
        {:ok, %{}}
      end)

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :starting
    end

    test "a retry reuses the existing credential — get-or-create, never rotate" do
      stub_kubeconfig()
      instance = deploying!(file_access: true)

      stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
      stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      expect(Secret, :create, fn _kc, _ns, "app-env", _data -> {:ok, %{}} end)

      expect(Secret, :get_data, fn _kc, _ns, "file-access" ->
        {:ok, %{"RCLONE_USER" => "fluxvale", "RCLONE_PASS" => "existing"}}
      end)

      # Any Secret.create here names "file-access" (the app-env one is
      # expected above) — a rotation attempt fails the expectation fn.
      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :starting
    end

    test "file access without a storage allocation lands no sidecar (nothing to serve)" do
      stub_kubeconfig()

      instance = deploying!(file_access: true, default_storage_gb: 0)

      stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
      stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      expect(ResourceQuota, :create, fn _kc, _ns, "app-quota", spec ->
        # unbumped: no sidecar overhead without a volume (Decimal, #222 F9)
        assert spec == %{cpu: Decimal.new("0.5"), memory: 512, storage: 0}
        {:ok, %{}}
      end)

      expect(Secret, :create, fn _kc, _ns, "app-env", _data -> {:ok, %{}} end)
      expect(Service, :create, fn _kc, _ns, "app", _spec -> {:ok, %{}} end)
      expect(Ingress, :create, fn _kc, _ns, "app-ingress", _spec -> {:ok, %{}} end)

      # No credential read without the sidecar; a stray "dav"
      # Service/Ingress create fails the expectations above (their fn
      # clauses match only "app"/"app-ingress").
      reject(Secret, :get_data, 3)

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :starting
    end

    test "a transient credential-read failure fails the deploy (never skips the sidecar)" do
      stub_kubeconfig()
      instance = deploying!(file_access: true)

      stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
      stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Secret, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      expect(Secret, :get_data, fn _kc, _ns, "file-access" ->
        {:error, K8s.Error.connection_error("api hiccup")}
      end)

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :error
      assert updated.status_message =~ "Deploy failed: api hiccup"
    end

    test "a dav-route apply failure fails the deploy after the app stack landed (review finding)" do
      stub_kubeconfig()
      instance = deploying!(file_access: true)

      stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
      stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Secret, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Ingress, :create, fn _kc, _ns, "app-ingress", _spec -> {:ok, %{}} end)

      stub(Secret, :get_data, fn _kc, _ns, "file-access" ->
        {:ok, %{"RCLONE_USER" => "u", "RCLONE_PASS" => "p"}}
      end)

      expect(Service, :create, fn _kc, _ns, "app", _spec -> {:ok, %{}} end)

      expect(Service, :create, fn _kc, _ns, "dav", _spec ->
        {:error, K8s.Error.connection_error("dav service rejected")}
      end)

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :error
      assert updated.status_message =~ "Deploy failed: dav service rejected"
    end
  end

  describe "call/1 — error paths" do
    test "a failed apply lands :error with the reason" do
      stub_kubeconfig()
      instance = deploying!()

      expect(Namespace, :create, fn _kc, _ns, _spec ->
        {:error, K8s.Error.connection_error("cluster on fire")}
      end)

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :error
      assert updated.status_message =~ "Deploy failed: cluster on fire"
      assert updated.failure_reason == :deploy_failed
    end

    test "a kubeconfig failure lands :error" do
      stub(K8s, :kubeconfig, fn nil -> {:error, K8s.Error.connection_error("no SA files")} end)

      instance = deploying!()

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :error
      assert updated.status_message =~ "Deploy failed"
      assert updated.failure_reason == :deploy_failed
    end

    test "the Deployment mounts the PVC at the instance's snapshotted path (#189)" do
      stub_kubeconfig()

      instance =
        deploying!(storage_mount_path: "/kavita/config", default_storage_gb: 10)

      ns = "fluxvale-app-#{instance.id}"
      expect(Namespace, :create, fn _kc, ^ns, _spec -> {:ok, %{}} end)
      stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Secret, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      expect(Deployment, :create, fn _kc, _ns, "app", spec ->
        # Not the platform default: the version's blueprint wins, so
        # Kavita's config dir lands on the volume.
        assert spec.storage_mount == "/kavita/config"
        assert spec.pvc_name == "app-data"
        {:ok, %{}}
      end)

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :starting
    end

    test "a forbidden from fresh-binding propagation is retried once and recovers (#238)" do
      stub_kubeconfig()
      instance = deploying!()
      ns = "fluxvale-app-#{instance.id}"

      stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
      stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Secret, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      # First quota apply rides the authorizer's pre-binding cache view
      # (the 403 the nightly artifact quotes verbatim); the retry —
      # after the propagation wait — succeeds.
      quota_attempts = :counters.new(1, [])

      forbidden =
        K8s.Error.from_response(
          {:ok,
           %{
             status: 403,
             body: %{
               "message" =>
                 "resourcequotas \"app-quota\" is forbidden: cannot patch resource \"resourcequotas\""
             }
           }}
        )

      expect(ResourceQuota, :create, 2, fn _kc, ^ns, "app-quota", _spec ->
        :counters.add(quota_attempts, 1, 1)

        if :counters.get(quota_attempts, 1) == 1,
          do: {:error, forbidden},
          else: {:ok, %{}}
      end)

      expect(SelfAccessReview, :wait_until_allowed, fn _kc, ^ns, "resourcequotas", "create" ->
        :ok
      end)

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :starting
    end

    test "a forbidden that persists after the propagation wait lands :error verbatim (#238)" do
      stub_kubeconfig()
      instance = deploying!()

      stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
      stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Secret, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

      expect(ResourceQuota, :create, 2, fn _kc, _ns, "app-quota", _spec ->
        {:error,
         K8s.Error.from_response(
           {:ok, %{status: 403, body: %{"message" => "quota grant genuinely absent"}}}
         )}
      end)

      expect(SelfAccessReview, :wait_until_allowed, fn _kc, _ns, "resourcequotas", "create" ->
        {:error, K8s.Error.timeout("RBAC propagation wait timed out")}
      end)

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :error
      assert updated.status_message =~ "Deploy failed: quota grant genuinely absent"
      assert updated.failure_reason == :deploy_failed
    end

    test "a non-:deploying instance is a no-op (superseded retry)" do
      instance = deploying!()

      {:ok, starting} = InstanceK8s.update_status(instance, :starting, nil)

      assert {:ok, returned} = DeployInstance.call(starting)
      assert returned.id == starting.id
    end
  end
end
