defmodule FluxVale.Infrastructure.Operations.DeployInstance do
  @moduledoc """
  K8s deploy orchestration for an Instance in `:deploying` — the AshOban
  `:deploy` trigger's body (ADR-0005).

  Applies, in order: Namespace → RoleBinding → ResourceQuota →
  NetworkPolicy → PVC → Secret(s) → Deployment → Service(s) → edge
  routes (`EdgeRoutes.apply_serving/2` — the IngressRoutes plus #203's
  activity-beacon Middleware; file-access instances add the
  `file-access` Secret and a `dav` Service whose route rides the same
  call — #190, ADR-0035; instances with bundled backing services add
  a `backing-services` Secret before their URLs join the env — #612,
  ADR-0045); then flips the Instance to `:starting` (K8s
  accepted, awaiting readiness — the reconciler owns `:running`) or
  `:error` with a status_message on failure.

  Ordering notes (mocked unit tests assert shape, not order — reason
  explicitly, v1's lesson):

  - the **RoleBinding precedes every namespaced operand**: the workload
    verbs it grants are what allow the platform SA to create the rest —
    and it is also *young* when the first operand applies: the
    authorizer ingests bindings asynchronously, a race tolerated in
    `apply_resources` (not by ordering, #238)
  - the **`backing-services` Secret precedes env composition** (#612):
    the URLs composed into the app's env are READ from it, so it must
    exist first — get-or-create, never rotated (the PG password hash
    lives in the data dir; an existing Secret IS the credential)
  - the **Secret precedes the Deployment**: the container references it
    via `envFrom.secretRef`, and a missing Secret at scheduling time is a
    transient `CreateContainerConfigError` the reconciler could misread
    as a `ReplicaFailure` — true for the app-env Secret, the
    file-access credential, and the backing-services credential alike
    (#190, #612)
  - the ResourceQuota lands before the Deployment so the quota is
    enforceable from the first pod, not retrofitted
  """

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Clients.K8s.SelfAccessReview
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  require Ash.Query
  require OpenTelemetry.Tracer

  @env_secret "app-env"

  # The propagation-wait probe (#238): the ResourceQuota is the first
  # operand that needs the workload RoleBinding, and its verbs come
  # only from that binding — once this canary is allowed, the binding
  # is visible to the authorizer, and so is every later operand's grant.
  @rbac_probe_resource "resourcequotas"
  @rbac_probe_verb "create"

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
        # ADR-0049 S1b: the deploy trigger is a background worker and
        # the instance carries no user FK — the event is anonymous.
        FluxVale.Analytics.capture("instance deployed", nil, %{
          instance_slug: instance.slug
        })

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
    # #196: the env label scopes namespace ownership — the orphan sweep
    # only deletes namespaces carrying its own platform_env, so two
    # platform envs sharing one physical cluster (ADR-0010 same-box)
    # can never treat each other's namespaces as orphans.
    namespace_labels = %{"fluxvale.io/platform-env" => platform_env()}

    with {:ok, spec} <- InstanceK8s.quota_spec(instance),
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
         {:ok, _pvc} <- InstanceK8s.maybe_create_pvc(kubeconfig, namespace, instance),
         # #612: get-or-create BEFORE env composition — the backing
         # URLs the env composes are read from this Secret.
         {:ok, backing_data} <-
           InstanceK8s.get_or_create_backing_secret(kubeconfig, namespace, instance),
         env = deploy_env(instance, backing_data),
         {:ok, _secret} <- maybe_create_secret(kubeconfig, namespace, env),
         {:ok, _file_secret} <-
           InstanceK8s.maybe_create_file_secret(kubeconfig, namespace, instance),
         {:ok, _deployment} <-
           Deployment.create(
             kubeconfig,
             namespace,
             "app",
             InstanceK8s.deployment_spec(instance, env)
           ),
         {:ok, _service} <- Service.create(kubeconfig, namespace, "app", service_spec(instance)),
         {:ok, _dav_service} <-
           InstanceK8s.maybe_create_dav_service(kubeconfig, namespace, instance) do
      InstanceK8s.apply_edge(kubeconfig, instance)
    end
  end

  # Serving routes now, dormant wake targets alongside: the first
  # sleep must only rewrite a route Traefik already watches (see
  # EdgeRoutes.ensure_wake_targets/2 for the observed alternative).
  # #265: a private instance gets neither's public half — apply_serving
  # converges on no routes, and wake targets without a route are
  # unreachable by design (nothing wakes a private instance). The edge
  # composition lives in InstanceK8s (`apply_edge/2`) — the resize's
  # 0→N crossing lands the same posture.

  # The merged env (catalog defaults under user values) plus the
  # instance's URL when the AppVersion asks for it (`instance_url_env` —
  # Forgejo's ROOT_URL; the URL isn't catalog data), plus each bundled
  # backing service's URL (#612, ADR-0045) from the get-or-create'd
  # backing Secret — the same deploy-time seed layer's stance: Map.put
  # ABOVE user env, the takeover precedence (create already rejects a
  # user value naming a url_env loudly; this holds even for drifted
  # rows).
  #
  # **ADR-0038 §4's omission rule, with its designed exception**
  # (ADR-0040 §7): a private row gets NO URL env — a dead ROOT_URL mints
  # dead links — EXCEPT when the row's default hostname is LIVE on a
  # CLAIMED domain (`:verified` + claimed on the org's gateway): the
  # hostname genuinely answers on the tailnet, so the URL and the
  # host-allowlist entry (`host_allowlist_env`, Django-class
  # ALLOWED_HOSTS) are real. Custom-hostname URL selection is S5's UI
  # problem — only the default hostname is modeled here. The env lands
  # on the first deploy that finds the conditions true (toggling later
  # doesn't rewrite a running app's env Secret — the next deploy does).
  defp deploy_env(instance, backing_data) do
    loaded = Ash.load(instance, :app_version, authorize?: false)

    case loaded do
      {:ok, instance} ->
        app_version = instance.app_version

        env =
          case url_value(instance, app_version) do
            nil ->
              instance.env_vars

            url ->
              env_name = url_env_name(app_version)
              Map.put(instance.env_vars, env_name, url)
          end

        env
        |> put_backing_urls(instance, backing_data)
        |> maybe_allowlist_entry(instance, app_version)

      # coveralls-ignore-start - defensive: a load failure is the DB
      # outage class ExUnit cannot stage (DBConnection reconnects by
      # design). Degrade to the bare env, never a crash: the deploy's
      # own error arms own real failures; env-seeding is derived sugar
      # on top of them.
      _load_failed ->
        instance.env_vars
        # coveralls-ignore-stop
    end
  end

  # The backing URLs (#612): nil data = the instance declares nothing.
  # fetch! is safe — get_or_create_backing_secret validated every
  # declared url_env key exists in the SAME apply, one step earlier.
  defp put_backing_urls(env, _instance, nil), do: env

  defp put_backing_urls(env, instance, data) do
    services = instance.backing_services

    Enum.reduce(services, env, fn service, acc ->
      Map.put(acc, service.url_env, Map.fetch!(data, service.url_env))
    end)
  end

  # Public rows: the URL as before. Private rows: only the claimed-
  # domain exception above. The env NAME may itself be nil — folded into
  # the same nil outcome (no URL wanted at all).
  defp url_value(instance, app_version) do
    cond do
      url_env_name(app_version) == nil -> nil
      instance.exposure == :public -> instance_url(instance)
      default_hostname_live?(instance) -> instance_url(instance)
      true -> nil
    end
  end

  defp url_env_name(app_version), do: app_version.instance_url_env

  # The allowlist entry rides the same claimed-domain condition: the
  # hostname APPENDS to whatever the catalog/user already set (Django
  # ALLOWED_HOSTS is a comma-separated list and the app's own defaults —
  # localhost et al — must survive us).
  defp maybe_allowlist_entry(env, instance, app_version) do
    env_name = app_version.host_allowlist_env

    if is_binary(env_name) and (instance.exposure == :public or default_hostname_live?(instance)) do
      hostname = "#{instance.slug}.#{Application.fetch_env!(:flux_vale, :instances_base_domain)}"
      Map.put(env, env_name, append_host(Map.get(env, env_name), hostname))
    else
      env
    end
  end

  defp append_host(nil, host), do: host
  defp append_host(existing, host) when is_binary(existing), do: "#{existing},#{host}"

  # LIVE on a claimed domain: the instance is ATTACHED (a live pairing —
  # the same record attach/detach read; an unattached private instance
  # answers nowhere, so the ADR-0038 §4 omission holds), the org's
  # gateway holds the claim for the base domain, AND the platform-domain
  # row is in a routable state (`:verified`/`:needs_attention` — the
  # same mirror the TLS clause routes). No gateway, no pairing, no
  # claim → no URL.
  #
  # ENV-SNAPSHOT STANCE: the env lands on the first deploy that finds
  # these conditions true. A later unclaim/detach does NOT rewrite a
  # running app's env Secret — the seeded URL goes stale by design
  # until the next deploy re-decides (the same stance as an exposure
  # toggle: toggling later doesn't rewrite a running app's env).
  defp default_hostname_live?(instance) do
    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)

    case AccessRoute.get_by_instance(instance.id, authorize?: false) do
      {:ok, _live_pairing} ->
        claimed_on_gateway?(instance, base_domain)

      # Unattached: the pairing row simply isn't there.
      {:error, _no_pairing} ->
        false
    end
  end

  defp claimed_on_gateway?(instance, base_domain) do
    case AccessGateway.get_for_organization(instance.organization_id, authorize?: false) do
      {:ok, %{dns_claims: claims}} when is_map(claims) ->
        Map.has_key?(claims, base_domain) and platform_domain_live?(instance, base_domain)

      _no_gateway_or_claims ->
        false
    end
  end

  defp platform_domain_live?(instance, base_domain) do
    query =
      Ash.Query.filter(
        AccessDomain,
        organization_id == ^instance.organization_id and
          kind == :platform and
          domain == ^base_domain
      )

    case Ash.read_one(query, authorize?: false) do
      {:ok, %{state: state}} ->
        state in [:verified, :needs_attention]

      # coveralls-ignore-start - defensive: the row cannot be missing
      # while this instance exists (its own default hostname FK-restricts
      # the platform row — the remove path refuses first), and a read
      # failure is the DB-outage class ExUnit cannot stage. Fail closed:
      # no URL.
      _no_row_or_read_failure ->
        false
        # coveralls-ignore-stop
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

  defp maybe_create_secret(kubeconfig, namespace, env) when map_size(env) > 0 do
    Secret.create(kubeconfig, namespace, @env_secret, env)
  end

  defp maybe_create_secret(_kubeconfig, _namespace, _env), do: {:ok, nil}

  # The file-access Secret and dav Service are the InstanceK8s seam's
  # (`maybe_create_file_secret/3`, `maybe_create_dav_service/3`) — the
  # resize's 0→N crossing mints the same objects.

  defp service_spec(instance) do
    %{
      port: 80,
      target_port: instance.port,
      selector: %{"app.kubernetes.io/name" => "app"}
    }
  end
end
