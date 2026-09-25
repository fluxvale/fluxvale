defmodule FluxVale.Infrastructure.Operations.DeployInstance do
  @moduledoc """
  K8s deploy orchestration for an Instance in `:deploying` — the AshOban
  `:deploy` trigger's body (ADR-0005).

  Applies, in order: Namespace → RoleBinding → ResourceQuota →
  NetworkPolicy → PVC → Secret → Deployment → Service → IngressRoute;
  then flips the Instance to `:starting` (K8s accepted, awaiting
  readiness — the reconciler owns `:running`) or `:error` with a
  status_message on failure.

  Ordering notes (mocked unit tests assert shape, not order — reason
  explicitly, v1's lesson):

  - the **RoleBinding precedes every namespaced operand**: the workload
    verbs it grants are what allow the platform SA to create the rest
  - the **Secret precedes the Deployment**: the container references it
    via `envFrom.secretRef`, and a missing Secret at scheduling time is a
    transient `CreateContainerConfigError` the reconciler could misread
    as a `ReplicaFailure`
  - the ResourceQuota lands before the Deployment so the quota is
    enforceable from the first pod, not retrofitted
  """

  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  @env_secret "app-env"

  @doc """
  Performs the deploy for a `:deploying` Instance. Returns `{:ok,
  instance}` either way — the `status` attribute carries the outcome
  (v1 contract, kept: the trigger treats both as processed).
  """
  @spec call(Instance.t()) :: {:ok, Instance.t()}
  def call(%{status: :deploying} = instance) do
    case InstanceK8s.kubeconfig_for(instance) do
      {:ok, kubeconfig} ->
        apply_then_transition(kubeconfig, instance)

      {:error, error} ->
        InstanceK8s.update_status(
          instance,
          :error,
          "Deploy failed: #{InstanceK8s.format_error(error)}"
        )
    end
  end

  # Oban retry racing another status writer (e.g. stale-deploy timeout):
  # the job is already superseded — processed, not failed.
  def call(instance), do: {:ok, instance}

  defp apply_then_transition(kubeconfig, instance) do
    namespace = instance.namespace

    case apply_resources(kubeconfig, namespace, instance) do
      :ok ->
        InstanceK8s.update_status(
          instance,
          :starting,
          "Deployed to Kubernetes; awaiting readiness"
        )

      {:error, error} ->
        InstanceK8s.update_status(
          instance,
          :error,
          "Deploy failed: #{InstanceK8s.format_error(error)}"
        )
    end
  end

  # Oban retry racing another status writer (e.g. stale-deploy timeout):
  # the job is already superseded — processed, not failed.

  defp apply_resources(kubeconfig, namespace, instance) do
    env = deploy_env(instance)

    with {:ok, _namespace} <- Namespace.create(kubeconfig, namespace, %{}),
         {:ok, _binding} <-
           RoleBinding.create(kubeconfig, namespace, "fluxvale-platform", role_binding_spec()),
         {:ok, _quota} <-
           ResourceQuota.create(kubeconfig, namespace, "app-quota", quota_spec(instance)),
         {:ok, _policy} <-
           NetworkPolicy.create(
             kubeconfig,
             namespace,
             "default-deny-ingress",
             network_policy_spec()
           ),
         {:ok, _pvc} <- maybe_create_pvc(kubeconfig, namespace, instance),
         {:ok, _secret} <- maybe_create_secret(kubeconfig, namespace, env),
         {:ok, _deployment} <-
           Deployment.create(kubeconfig, namespace, "app", deployment_spec(instance, env)),
         {:ok, _service} <- Service.create(kubeconfig, namespace, "app", service_spec(instance)),
         {:ok, _ingress} <-
           Ingress.create(kubeconfig, namespace, "app-ingress", ingress_spec(instance)) do
      :ok
    end
  end

  # The merged env (catalog defaults under user values) plus the
  # instance's public URL when the AppVersion asks for it
  # (`instance_url_env` — Forgejo's ROOT_URL; the URL isn't catalog data).
  defp deploy_env(instance) do
    with {:ok, instance} <- Ash.load(instance, :app_version, authorize?: false),
         env_name when not is_nil(env_name) <- instance.app_version.instance_url_env do
      Map.put(instance.env_vars, env_name, instance_url(instance))
    else
      _no_url_env -> instance.env_vars
    end
  end

  defp instance_url(instance) do
    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)
    "https://#{instance.slug}.#{base_domain}/"
  end

  defp role_binding_spec do
    config = Application.fetch_env!(:flux_vale, :instance_rbac)

    %{
      service_account: config[:service_account],
      service_account_namespace: config[:service_account_namespace],
      role: config[:workload_role]
    }
  end

  defp quota_spec(instance) do
    %{
      cpu: Decimal.to_float(instance.cpu_cores),
      memory: instance.memory_mb,
      storage: instance.storage_gb
    }
  end

  # Config-driven like its RBAC siblings: prod's Traefik may not live in
  # "traefik", and a wrong namespace would silently drop all edge ingress.
  defp network_policy_spec do
    edge = Application.fetch_env!(:flux_vale, :instance_ingress_namespace)
    %{ingress_from_namespaces: [edge]}
  end

  defp maybe_create_pvc(kubeconfig, namespace, %{storage_gb: gb}) when gb > 0 do
    PersistentVolumeClaim.create(kubeconfig, namespace, "app-data", %{size: "#{gb}Gi"})
  end

  defp maybe_create_pvc(_kubeconfig, _namespace, _instance), do: {:ok, nil}

  defp maybe_create_secret(kubeconfig, namespace, env) when map_size(env) > 0 do
    Secret.create(kubeconfig, namespace, @env_secret, env)
  end

  defp maybe_create_secret(_kubeconfig, _namespace, _env), do: {:ok, nil}

  defp deployment_spec(instance, env) do
    %{
      image: instance.image,
      port: instance.port,
      cpu: Decimal.to_float(instance.cpu_cores),
      memory: instance.memory_mb,
      probe_path: instance.healthcheck_path,
      storage_mount: storage_mount_path(instance),
      pvc_name: pvc_name(instance),
      env_from_secret: if(env != %{}, do: @env_secret)
    }
  end

  defp service_spec(instance) do
    %{
      port: 80,
      target_port: instance.port,
      selector: %{"app.kubernetes.io/name" => "app"}
    }
  end

  defp ingress_spec(instance) do
    %{
      subdomain: instance.slug,
      service_name: "app",
      service_port: 80,
      tls: true,
      domain: Application.fetch_env!(:flux_vale, :instances_base_domain)
    }
  end

  defp storage_mount_path(%{storage_gb: gb}) when gb > 0, do: "/data"
  defp storage_mount_path(_instance), do: nil

  defp pvc_name(%{storage_gb: gb}) when gb > 0, do: "app-data"
  defp pvc_name(_instance), do: nil
end
