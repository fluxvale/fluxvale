defmodule FluxVale.Infrastructure.Operations.DeployInstanceTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
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
  end

  describe "call/1" do
    test "applies every namespace resource with the instance's blueprint" do
      stub_kubeconfig()
      instance = deploying!()
      ns = "fluxvale-app-#{instance.id}"

      expect(Namespace, :create, fn _kc, ^ns, %{} -> {:ok, %{}} end)

      expect(RoleBinding, :create, fn _kc, ^ns, "fluxvale-platform", spec ->
        assert spec == %{
                 service_account: "fluxvale-platform",
                 service_account_namespace: "fluxvale-dev",
                 role: "fluxvale-platform-workload"
               }

        {:ok, %{}}
      end)

      expect(ResourceQuota, :create, fn _kc, ^ns, "app-quota", spec ->
        assert spec == %{cpu: 0.5, memory: 512, storage: 10}
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

    test "a failed apply lands :error with the reason" do
      stub_kubeconfig()
      instance = deploying!()

      expect(Namespace, :create, fn _kc, _ns, _spec ->
        {:error, K8s.Error.connection_error("cluster on fire")}
      end)

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :error
      assert updated.status_message =~ "Deploy failed: cluster on fire"
    end

    test "a kubeconfig failure lands :error" do
      stub(K8s, :kubeconfig, fn nil -> {:error, K8s.Error.connection_error("no SA files")} end)

      instance = deploying!()

      assert {:ok, updated} = DeployInstance.call(instance)
      assert updated.status == :error
      assert updated.status_message =~ "Deploy failed"
    end

    test "a non-:deploying instance is a no-op (superseded retry)" do
      instance = deploying!()

      {:ok, starting} = InstanceK8s.update_status(instance, :starting, nil)

      assert {:ok, returned} = DeployInstance.call(starting)
      assert returned.id == starting.id
    end
  end
end
