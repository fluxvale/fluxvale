defmodule FluxVale.Infrastructure.Operations.DeployInstance do
  @moduledoc """
  K8s deploy orchestration for an Instance in `:deploying` — the AshOban
  `:deploy` trigger's body (ADR-0005).

  Applies, in order: Namespace → RoleBinding → ResourceQuota →
  NetworkPolicy → PVC → Secret(s) → Deployment → Service(s) → edge
  routes (`EdgeRoutes.apply_serving/2` — the IngressRoutes plus #203's
  activity-beacon Middleware; file-access instances add the
  `file-access` Secret and a `dav` Service whose route rides the same
  call — #190, ADR-0035); then flips the Instance to `:starting` (K8s
  accepted, awaiting readiness — the reconciler owns `:running`) or
  `:error` with a status_message on failure.

  Ordering notes (mocked unit tests assert shape, not order — reason
  explicitly, v1's lesson):

  - the **RoleBinding precedes every namespaced operand**: the workload
    verbs it grants are what allow the platform SA to create the rest —
    and it is also *young* when the first operand applies: the
    authorizer ingests bindings asynchronously, a race tolerated in
    `apply_resources` (not by ordering, #238)
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
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Clients.K8s.SelfAccessReview
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  require Ash.Query
  require OpenTelemetry.Tracer

  @env_secret "app-env"
  @file_secret "file-access"
  @dav_service "dav"

  # The propagation-wait probe (#238): the ResourceQuota is the first
  # operand that needs the workload RoleBinding, and its verbs come
  # only from that binding — once this canary is allowed, the binding
  # is visible to the authorizer, and so is every later operand's grant.
  @rbac_probe_resource "resourcequotas"
  @rbac_probe_verb "create"

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
    case apply_operands(kubeconfig, namespace, instance) do
      # #238: a 403 from these operands is usually not a bad grant but
      # a young one — see retry_after_rbac_propagation/3.
      {:error, %Error{reason: :forbidden}} ->
        retry_after_rbac_propagation(kubeconfig, namespace, instance)

      result ->
        result
    end
  end

  # On a forbidden operand: wait out workload-RBAC propagation, then
  # re-run the whole sequence once. The workload RoleBinding is the
  # operand verbs' only source (#69's split), and the API server
  # authorizes against an informer-cached view of bindings — one
  # created in this same deploy may not be visible yet when the first
  # operand applies, which then 403s (nightly run 40049475058, on
  # #238, caught the race with surviving artifacts). The re-run is
  # safe — every operand is a server-side apply, so re-applying is a
  # no-op where it already succeeded.
  #
  # Trade-off: a genuinely bad grant (never propagation) also pays the
  # bounded wait (~5s) plus one redundant SSA round before landing the
  # same verbatim 403 — the API server's message in status_message is
  # the diagnostic we keep either way, so the wait deliberately does
  # not gate the retry.
  defp retry_after_rbac_propagation(kubeconfig, namespace, instance) do
    SelfAccessReview.wait_until_allowed(
      kubeconfig,
      namespace,
      @rbac_probe_resource,
      @rbac_probe_verb
    )

    apply_operands(kubeconfig, namespace, instance)
  end

  defp apply_operands(kubeconfig, namespace, instance) do
    env = deploy_env(instance)

    # #196: the env label scopes namespace ownership — the orphan sweep
    # only deletes namespaces carrying its own platform_env, so two
    # platform envs sharing one physical cluster (ADR-0010 same-box)
    # can never treat each other's namespaces as orphans.
    namespace_labels = %{"fluxvale.io/platform-env" => platform_env()}

    with {:ok, spec} <- quota_spec(instance),
         {:ok, _namespace} <- Namespace.create(kubeconfig, namespace, %{labels: namespace_labels}),
         {:ok, _binding} <-
           RoleBinding.create(kubeconfig, namespace, "fluxvale-platform", role_binding_spec()),
         {:ok, _quota} <- ResourceQuota.create(kubeconfig, namespace, "app-quota", spec),
         {:ok, _policy} <-
           NetworkPolicy.create(
             kubeconfig,
             namespace,
             "default-deny-ingress",
             # #268: the spec comes from the INSTANCE, not the exposure
             # atom, so a redeploy of an attached instance preserves (and
             # pod-narrows) its gateway peer instead of silently severing
             # private access. Private deploys still deny edge ingress
             # from the first pod (#265), not retroactively.
             InstanceK8s.network_policy_spec(instance)
           ),
         {:ok, _pvc} <- maybe_create_pvc(kubeconfig, namespace, instance),
         {:ok, _secret} <- maybe_create_secret(kubeconfig, namespace, env),
         {:ok, _file_secret} <- maybe_create_file_secret(kubeconfig, namespace, instance),
         {:ok, _deployment} <-
           Deployment.create(kubeconfig, namespace, "app", deployment_spec(instance, env)),
         {:ok, _service} <- Service.create(kubeconfig, namespace, "app", service_spec(instance)),
         {:ok, _dav_service} <- maybe_create_dav_service(kubeconfig, namespace, instance) do
      deploy_edge(kubeconfig, instance)
    end
  end

  # Serving routes now, dormant wake targets alongside: the first
  # sleep must only rewrite a route Traefik already watches (see
  # EdgeRoutes.ensure_wake_targets/2 for the observed alternative).
  # #265: a private instance gets neither's public half — apply_serving
  # converges on no routes, and wake targets without a route are
  # unreachable by design (nothing wakes a private instance).
  defp deploy_edge(kubeconfig, instance) do
    with :ok <- EdgeRoutes.apply_serving(kubeconfig, instance),
         :ok <- maybe_access_serving(kubeconfig, instance) do
      maybe_wake_targets(kubeconfig, instance)
    end
  end

  defp maybe_wake_targets(_kubeconfig, %{exposure: :private}), do: :ok

  defp maybe_wake_targets(kubeconfig, instance),
    do: EdgeRoutes.ensure_wake_targets(kubeconfig, instance)

  # S2 (ADR-0040 §7): an attached private instance's deploy mints its
  # access serving arms alongside the (empty) public posture — the
  # dispatch lives inside the exposure branches so callers stay
  # exposure-blind. The status is :deploying/:starting here, but the
  # arms are the serving set by design: the app is what comes up next,
  # and the dormant wake targets ride along for the first sleep.
  defp maybe_access_serving(kubeconfig, %{exposure: :private} = instance) do
    instance_id = instance.id

    # The pairing row is the durable record of "attached" (the policy
    # spec's own source). A read that fails raises: a DB blip is not
    # "unattached", and deploy_failed owns error tuples, not raises —
    # the Oban retry owns the pass.
    case AccessRoute
         |> Ash.Query.filter(instance_id == ^instance_id)
         |> Ash.read_one!(authorize?: false) do
      nil ->
        # Unattached private is panel-only (#265): no hostnames serve
        # anywhere, nothing to mint.
        :ok

      route ->
        with {:ok, route} <- Ash.load(route, :gateway, authorize?: false) do
          EdgeRoutes.apply_access_serving(kubeconfig, route.gateway, instance)
        end
    end
  end

  defp maybe_access_serving(_kubeconfig, _public), do: :ok

  # The merged env (catalog defaults under user values) plus the
  # instance's public URL when the AppVersion asks for it
  # (`instance_url_env` — Forgejo's ROOT_URL; the URL isn't catalog
  # data). Private rows get NO URL (PR #267 review round 2): the
  # address never serves, and an app seeded with a dead ROOT_URL
  # mints dead links of its own. The env lands on the first deploy
  # that finds the row public (toggling later doesn't rewrite a
  # running app's env Secret — the next deploy does).
  defp deploy_env(instance) do
    with {:ok, instance} <- Ash.load(instance, :app_version, authorize?: false),
         env_name when not is_nil(env_name) <- instance.app_version.instance_url_env,
         :public <- instance.exposure do
      Map.put(instance.env_vars, env_name, instance_url(instance))
    else
      _no_public_url -> instance.env_vars
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
    memory = instance.memory_mb

    # The sidecar is platform overhead, not purchased allocation: the
    # quota widens by exactly its requests so the app pod's share stays
    # what the user chose (ADR-0035). CPU stays Decimal end to end —
    # float math rounds (0.35 + 0.05) and a quota below the pod's exact
    # request sum is rejected at admission.
    total_cpu =
      if file_access?(instance),
        do: Decimal.add(instance.cpu_cores, @sidecar_cpu),
        else: instance.cpu_cores

    total_memory = if(file_access?(instance), do: memory + @sidecar_memory_mb, else: memory)

    # #222 (ADR-0037 §3): the backup Job runs in this namespace too, so a
    # configured setting widens the quota by its requests — same
    # platform-overhead arithmetic as the sidecar above. Read here (not
    # passed in) so a re-apply never lags the row; the row is
    # authoritative and ConfigureBackups writes it after the k8s apply.
    with {:ok, quota} <- maybe_backup_margin(instance, {total_cpu, total_memory}) do
      {final_cpu, final_memory} = quota

      {:ok,
       %{
         cpu: final_cpu,
         memory: final_memory,
         storage: instance.storage_gb
       }}
    end
  end

  # #222 (ADR-0037 §3): the margin persists while the settings row
  # exists — configured, enabled or not. Disabling is a plain row update,
  # so gating the margin on `enabled` would let disable → redeploy →
  # re-enable leave a narrow quota behind and pend every backup Job.
  defp maybe_backup_margin(instance, {cpu, memory}) do
    case backups_configured?(instance) do
      {:ok, true} ->
        config = Application.fetch_env!(:flux_vale, :backups)
        cpu_request = Decimal.add(cpu, Decimal.new(config[:cpu_cores]))

        {:ok, {cpu_request, memory + config[:memory_mb]}}

      {:ok, false} ->
        {:ok, {cpu, memory}}

      # coveralls-ignore-start - defensive: a DB failure here (outage,
      # dropped connection) is the one ExUnit can't stage; DBConnection
      # reconnects by design. The non-bang call returns it instead of
      # raising through the Oban job, which is the point.
      {:error, error} ->
        {:error, error}
        # coveralls-ignore-stop
    end
  end

  # Non-bang on purpose: a DB blip returns an error the deploy's `with`
  # chain threads to `deploy_failed`, like every other step — a bang would
  # raise straight through the Oban job.
  #
  # authorize?: false — deploy runs in the trigger context (no actor);
  # the row is system-written by ConfigureBackups, which carried the
  # member's policy check.
  defp backups_configured?(instance) do
    BackupSetting
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.exists(authorize?: false)
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
  # app's Service stays untouched; the route itself is EdgeRoutes' (it
  # owns every ingress shape, #203).
  defp maybe_create_dav_service(kubeconfig, namespace, instance) do
    if file_access?(instance) do
      Service.create(kubeconfig, namespace, @dav_service, dav_service_spec())
    else
      {:ok, nil}
    end
  end

  defp dav_service_spec do
    %{
      port: 80,
      target_port: file_access_config(:port),
      selector: %{"app.kubernetes.io/name" => "app"}
    }
  end

  defp service_spec(instance) do
    %{
      port: 80,
      target_port: instance.port,
      selector: %{"app.kubernetes.io/name" => "app"}
    }
  end

  defp storage_mount_path(%{storage_gb: gb, storage_mount_path: path}) when gb > 0, do: path
  defp storage_mount_path(_instance), do: nil

  defp pvc_name(%{storage_gb: gb}) when gb > 0, do: "app-data"
  defp pvc_name(_instance), do: nil
end
