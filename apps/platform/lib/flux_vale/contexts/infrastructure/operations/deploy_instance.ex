defmodule FluxVale.Infrastructure.Operations.DeployInstance do
  @moduledoc """
  K8s deploy orchestration for an Instance in `:deploying` — the AshOban
  `:deploy` trigger's body (ADR-0005).

  Applies, in order: Namespace → RoleBinding → ResourceQuota →
  NetworkPolicy → PVC → Secret(s) → Deployment → Service → IngressRoute
  (file-access instances add the `file-access` Secret, a `dav` Service,
  and an `app-dav` IngressRoute — #190, ADR-0035); then flips the
  Instance to `:starting` (K8s accepted, awaiting readiness — the
  reconciler owns `:running`) or `:error` with a status_message on
  failure.

  Ordering notes (mocked unit tests assert shape, not order — reason
  explicitly, v1's lesson):

  - the **RoleBinding precedes every namespaced operand**: the workload
    verbs it grants are what allow the platform SA to create the rest
  - the **Secret precedes the Deployment**: the container references it
    via `envFrom.secretRef`, and a missing Secret at scheduling time is a
    transient `CreateContainerConfigError` the reconciler could misread
    as a `ReplicaFailure` — true for the app-env Secret and the
    file-access credential alike (#190)
  - the ResourceQuota lands before the Deployment so the quota is
    enforceable from the first pod, not retrofitted
  """

  alias FluxVale.Clients.K8s.Error
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

  require OpenTelemetry.Tracer

  @env_secret "app-env"
  @file_secret "file-access"
  @dav_service "dav"
  @dav_ingress "app-dav"

  # Sidecar requests (ADR-0035): platform overhead on top of the
  # purchased allocation — the ResourceQuota widens by exactly this
  # (limits ride the builders' 2x-requests convention). Decimal, not
  # float: the quota addition must not round (see quota_spec).
  @sidecar_cpu Decimal.new("0.05")
  @sidecar_memory_mb 64

  @doc """
  Performs the deploy for a `:deploying` Instance. Returns `{:ok,
  instance}` either way — the `status` attribute carries the outcome
  (v1 contract, kept: the trigger treats both as processed).

  The whole orchestration is one `instance.deploy` span (ADR-0012
  Am. 1) — Oban trigger → apply → transition is the product's most
  valuable trace.
  """
  @spec call(Instance.t()) :: {:ok, Instance.t()}
  def call(%{status: :deploying} = instance) do
    OpenTelemetry.Tracer.with_span "instance.deploy", deploy_span_attrs(instance) do
      deploy(instance)
    end
  end

  # Oban retry racing another status writer (e.g. stale-deploy timeout):
  # the job is already superseded — processed, not failed. No work, no span.
  def call(instance), do: {:ok, instance}

  defp deploy(instance) do
    case InstanceK8s.kubeconfig_for(instance) do
      {:ok, kubeconfig} ->
        apply_then_transition(kubeconfig, instance)

      {:error, error} ->
        deploy_failed(instance, error)
    end
  end

  defp deploy_span_attrs(instance) do
    # OTLP attribute keys are strings
    %{
      attributes: %{
        "instance.id" => instance.id,
        "instance.slug" => instance.slug,
        "instance.namespace" => instance.namespace
      }
    }
  end

  defp deploy_failed(instance, error) do
    message = "Deploy failed: #{InstanceK8s.format_error(error)}"

    OpenTelemetry.Tracer.set_status(:error, message)

    InstanceK8s.update_status(instance, :error, message, :deploy_failed)
  end

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
        deploy_failed(instance, error)
    end
  end

  defp apply_resources(kubeconfig, namespace, instance) do
    env = deploy_env(instance)

    # #196: the env label scopes namespace ownership — the orphan sweep
    # only deletes namespaces carrying its own platform_env, so two
    # platform envs sharing one physical cluster (ADR-0010 same-box)
    # can never treat each other's namespaces as orphans.
    namespace_labels = %{"fluxvale.io/platform-env" => platform_env()}

    with {:ok, _namespace} <- Namespace.create(kubeconfig, namespace, %{labels: namespace_labels}),
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
         {:ok, _file_secret} <- maybe_create_file_secret(kubeconfig, namespace, instance),
         {:ok, _deployment} <-
           Deployment.create(kubeconfig, namespace, "app", deployment_spec(instance, env)),
         {:ok, _service} <- Service.create(kubeconfig, namespace, "app", service_spec(instance)),
         {:ok, _ingress} <-
           Ingress.create(kubeconfig, namespace, "app-ingress", ingress_spec(instance)) do
      maybe_create_dav_route(kubeconfig, namespace, instance)
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

  # #196: the owning platform env (config.exs/runtime.exs) — labels the
  # instance namespace at deploy; the orphan sweep matches it.
  defp platform_env do
    Application.fetch_env!(:flux_vale, :platform_env)
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
    cpu = Decimal.to_float(instance.cpu_cores)
    memory = instance.memory_mb

    # The sidecar is platform overhead, not purchased allocation: the
    # quota widens by exactly its requests so the app pod's share stays
    # what the user chose (ADR-0035). The addition stays in Decimal —
    # float math rounds down on legal allocations (0.35 + 0.05) and a
    # quota below the pod's exact request sum is rejected at admission.
    total_cpu =
      if file_access?(instance),
        do: Decimal.add(instance.cpu_cores, @sidecar_cpu),
        else: cpu

    total_memory = if(file_access?(instance), do: memory + @sidecar_memory_mb, else: memory)

    %{
      cpu: total_cpu,
      memory: total_memory,
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

  # File access is on (and has a volume to serve) only when the app
  # declared it AND the instance allocated storage — a file-access app
  # at 0 GB has nothing to mount, so the sidecar silently doesn't land
  # (the wizard allows 0 GB with only a heads-up, so this is an ordinary
  # outcome, not a crafted one; the instance page gates its panel the
  # same way).
  defp file_access?(%{file_access: true, storage_gb: gb}) when gb > 0, do: true
  defp file_access?(_instance), do: false

  # Get-or-create, never blind-apply: a retrying deploy must not rotate
  # a credential the owner already configured rclone with — the secret
  # is the credential's home (ADR-0035's storage decision), so an
  # existing row IS the credential.
  defp maybe_create_file_secret(kubeconfig, namespace, instance) do
    if file_access?(instance) do
      case Secret.get_data(kubeconfig, namespace, @file_secret) do
        {:ok, _existing} -> {:ok, nil}
        {:error, %Error{reason: :not_found}} -> create_file_secret(kubeconfig, namespace)
        {:error, _error} = error -> error
      end
    else
      {:ok, nil}
    end
  end

  defp create_file_secret(kubeconfig, namespace) do
    # rclone reads basic auth straight from these env vars (RCLONE_USER/
    # RCLONE_PASS are the env forms of serve's --user/--pass) — the
    # Secret lands them in the container via envFrom, no shell, no
    # command-line exposure of the password.
    data = %{
      "RCLONE_USER" => file_access_config(:username),
      "RCLONE_PASS" => credential_password()
    }

    Secret.create(kubeconfig, namespace, @file_secret, data)
  end

  # 32 bytes of CSPRNG entropy, URL-safe base64 (43 chars): rclone
  # accepts any string; this keeps it copy-paste safe for rclone config.
  defp credential_password do
    entropy = :crypto.strong_rand_bytes(32)
    Base.url_encode64(entropy, padding: false)
  end

  # The rclone serve command (ADR-0035): WebDAV over the shared data
  # volume, under the route's path prefix, auth from the Secret's env.
  # Serves the app's own `storage_mount_path` — for Kavita that's
  # /kavita/config, and since its libraries live in subdirs of the same
  # volume, serving the mount root exposes the whole volume (#189/#190).
  defp sidecar_spec(instance) do
    config = file_access_config()
    mount_path = instance.storage_mount_path

    %{
      image: config[:image],
      port: config[:port],
      args: [
        "serve",
        "webdav",
        mount_path,
        "--addr",
        "0.0.0.0:#{config[:port]}",
        "--baseurl",
        config[:path_prefix]
      ],
      env_from_secret: @file_secret,
      storage_mount: mount_path,
      cpu: @sidecar_cpu,
      memory: @sidecar_memory_mb
    }
  end

  defp file_access_config do
    Application.fetch_env!(:flux_vale, :file_access)
  end

  defp file_access_config(key) do
    file_access_config()[key]
  end

  defp deployment_spec(instance, env) do
    base = %{
      image: instance.image,
      port: instance.port,
      cpu: Decimal.to_float(instance.cpu_cores),
      memory: instance.memory_mb,
      probe_path: instance.healthcheck_path,
      storage_mount: storage_mount_path(instance),
      pvc_name: pvc_name(instance),
      env_from_secret: if(env != %{}, do: @env_secret)
    }

    if file_access?(instance), do: Map.put(base, :sidecar, sidecar_spec(instance)), else: base
  end

  # The WebDAV route rides the instance hostname under the path prefix
  # (Host(`slug.domain`) && PathPrefix(`/dav`) — Traefik auto-prioritizes
  # the longer match above the app's bare Host rule), own Service so the
  # app's Service/IngressRoute stay untouched.
  defp maybe_create_dav_route(kubeconfig, namespace, instance) do
    if file_access?(instance) do
      with {:ok, _service} <-
             Service.create(kubeconfig, namespace, @dav_service, dav_service_spec()),
           {:ok, _ingress} <-
             Ingress.create(kubeconfig, namespace, @dav_ingress, dav_ingress_spec(instance)) do
        :ok
      end
    else
      :ok
    end
  end

  defp dav_service_spec do
    %{
      port: 80,
      target_port: file_access_config(:port),
      selector: %{"app.kubernetes.io/name" => "app"}
    }
  end

  defp dav_ingress_spec(instance) do
    %{
      subdomain: instance.slug,
      service_name: @dav_service,
      service_port: 80,
      tls: true,
      domain: Application.fetch_env!(:flux_vale, :instances_base_domain),
      path_prefix: file_access_config(:path_prefix)
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

  defp storage_mount_path(%{storage_gb: gb, storage_mount_path: path}) when gb > 0, do: path
  defp storage_mount_path(_instance), do: nil

  defp pvc_name(%{storage_gb: gb}) when gb > 0, do: "app-data"
  defp pvc_name(_instance), do: nil
end
