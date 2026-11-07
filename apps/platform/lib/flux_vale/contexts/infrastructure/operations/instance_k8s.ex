defmodule FluxVale.Infrastructure.Operations.InstanceK8s do
  @moduledoc """
  Shared seam for the Instance lifecycle operations: cluster kubeconfig
  resolution, system status writes, K8s error formatting, and — since
  #493 — the workload spec builders (quota/PVC/deployment, beside
  network_policy_spec) the deploy and the resize both apply.

  Not a user-facing operation — the verb modules (Deploy/Reconcile/
  Teardown/Stop/Start/ResizeInstance) own the lifecycle decisions; this
  owns the mechanics they need identically (the one sanctioned shared
  helper set — duplicating it six times is the boundary error, not
  sharing it).
  """

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.EdgeRoutes

  require Ash.Query

  @doc """
  Resolves the Instance's cluster and its kubeconfig. Cluster read runs
  `authorize?: false` — placement is global config, not actor-scoped data
  (the Cluster policy posture, #72).

  Spec'd `map()`, not `Instance.t()`: an `Instance.t()` arg here makes
  dialyzer collapse the contract to the error branch at the lifecycle
  ops' call sites (the with/Ash.get inference chain) — map() keeps the
  contract honest for every caller shape.
  """
  @spec kubeconfig_for(map()) ::
          {:ok, Kubereq.Kubeconfig.t()} | {:error, term()}
  def kubeconfig_for(%{cluster_id: cluster_id}) do
    with {:ok, cluster} <- Ash.get(Cluster, cluster_id, authorize?: false) do
      K8s.kubeconfig(cluster.kubeconfig_ref)
    end
  end

  @doc """
  System status write through `:update_status`. `authorize?: false`: the
  trigger context has no actor and the AshOban bypass doesn't propagate
  to nested calls — the user-facing entry actions (deploy/stop/start/
  delete) carry the ownership policy check. The namespace never changes
  here: it is write-once, pinned by the deploy action.

  `failure_reason` (#179) travels with the status: set only when landing
  `:error` (the friendly-copy classification), forced nil on every other
  write — a recovery can never inherit the previous failure's reason.
  """
  @spec update_status(Instance.t(), atom(), String.t() | nil, atom() | nil) ::
          {:ok, Instance.t()} | {:error, term()}
  def update_status(instance, status, status_message, failure_reason \\ nil) do
    # The resource validates status_message at 500 codepoints (ash counts
    # codepoints since the :codepoints default) and K8s condition strings
    # routinely exceed it. Truncate in codepoints so the cut counts the
    # same unit the validation counts and the write never fails.
    params = %{
      status: status,
      status_message: truncate(status_message, 500),
      failure_reason: if(status == :error, do: failure_reason)
    }

    instance
    |> Ash.Changeset.for_update(:update_status, params, authorize?: false)
    |> Ash.update()
  end

  @doc """
  Formats a K8s/client error into a status_message-worthy string.
  """
  @spec format_error(term()) :: String.t()
  def format_error(%{message: message}) when is_binary(message), do: message
  # coveralls-ignore-next-line - defensive: K8s errors are %Error{} or strings
  def format_error(other), do: inspect(other)

  @doc """
  The namespace's ingress policy spec (#265) — **the one source both
  writers use**, so the exposure floor and the access layer cannot
  disagree about the same object.

  The exposure floor is the only posture the toggle and the deploy own:
  public admits the edge namespace (Traefik) on top of same-namespace
  traffic; private admits same-namespace only. Same-namespace is always
  the NetworkPolicy client's own floor, and it is not part of the spec.

  **Admitted access-gateway peers are preserved, not dropped.** The
  policy is one object per namespace with two independent dimensions:
  the edge entry (this module's business) and the gateway peer (the
  access layer's). A rewrite from the exposure floor alone would delete
  the gateway peer while the AccessRoute row and the billing survived —
  the instance silently unreachable, nothing self-healing it. So the
  spec is built from the instance's *routes*, the durable record of who
  is attached, which is why this takes the record rather than the
  exposure atom.

  Called by `DeployInstance` (the deploy-time apply) and `SetExposure`
  (the toggle's re-apply) — the two writers of the same object.

  **The private+attached edge admission (ADR-0040 Am. 1)**: the access
  gateway tunnels raw 443 to the SAME Traefik deployment, whose `access`
  entrypoint terminates the tunnel and dials the app Service — so while
  an instance is private AND attached, the policy admits the edge
  namespace alongside the gateway peer. Deliberate and test-pinned: the
  widening exists only in that one state (an unattached private instance
  stays panel-only; a public instance's edge admission is the exposure
  floor's, unchanged by attachment). Public darkness is untouched — no
  public route exists for a private instance; resolution still decides.
  """
  @spec network_policy_spec(map()) ::
          %{required(:ingress_from_namespaces) => [String.t()]}
          | %{required(:ingress_from_sources) => [map()]}
  def network_policy_spec(%{exposure: exposure} = instance) do
    gateways = gateway_peers(instance)
    peers = exposure_peers(exposure, gateways)

    case gateways do
      # No gateway attached: the plain exposure floor (the pre-#268 shape).
      [] ->
        %{ingress_from_namespaces: peers}

      # Attached: the edge entry stays whole-namespace (Traefik pods are
      # not ours to label), the gateway entry is narrowed to the gateway's
      # own pods — otherwise org B's gateway would reach org A's app.
      _attached ->
        %{ingress_from_sources: Enum.map(peers, &%{namespace: &1}) ++ gateways}
    end
  end

  defp exposure_peers(:public, _gateways) do
    [Application.fetch_env!(:flux_vale, :instance_ingress_namespace)]
  end

  # Private: no edge entry for the unattached (the empty list IS the
  # denial — not a removed policy, which would re-admit everything).
  # Attached, the access edge's own dial joins (Amendment 1, above).
  defp exposure_peers(:private, []), do: []

  defp exposure_peers(:private, _gateways) do
    [Application.fetch_env!(:flux_vale, :instance_ingress_namespace)]
  end

  # Every attached gateway, as a namespace + pod-selector peer. The
  # labels mirror the provider's Deployment selector; they are the one
  # cross-module constant this pairing depends on.
  defp gateway_peers(instance) do
    instance
    |> attached_gateway_ids()
    |> Enum.flat_map(fn gateway_id ->
      # The list wrapper is load-bearing: flat_map over a bare map
      # iterates its key/value TUPLES, so the spec would carry
      # {:namespace, "…"} instead of the peer map and every exposure
      # apply would fail.
      [%{namespace: gateway_access_namespace(), match_labels: gateway_pod_labels(gateway_id)}]
    end)
  end

  @doc """
  The cluster path label for a gateway Deployment — the selector the
  provider uses and the NetworkPolicy peers must match. This is the single
  source of the namespace-derived gateway identity.
  """
  @spec gateway_pod_labels(Ash.UUID.t()) :: %{optional(String.t()) => String.t()}
  def gateway_pod_labels(gateway_id) do
    %{
      "app.kubernetes.io/name" => "access-gateway",
      "fluxvale.io/gateway" => gateway_id
    }
  end

  @doc """
  The platform's access namespace — one shared namespace for every
  org's gateway (ADR-0039 §1) — and the ONE source of truth for
  gateway placement.

  Called by the deploy/exposure-apply paths (`network_policy_spec/1`,
  via DeployInstance and SetExposure) and by the provider callbacks
  (`Tailscale.access_namespace/0`). A missing config key must fail
  loudly: at base, attach admitted the peer into the provider's
  `"fluxvale-access"` fallback while the instance-side spec builder
  dropped the peer on the next exposure flip or redeploy, silently
  severing reachability on every reconfigure.

  The provider calls this directly — the resolver raises `KeyError` on
  a missing key. Caller-side fallback to nil is not safe; attach must
  reject misconfig at the start.
  """
  @spec gateway_access_namespace() :: String.t()
  def gateway_access_namespace do
    config = Application.fetch_env!(:flux_vale, :access_gateway)

    # The single clause matches only a usable namespace: a nil/empty
    # VALUE fails as loudly as a missing key (an env-var interpolation
    # that yields nil is one deploy away) — CaseClauseError, not a
    # half-configured attach.
    case Keyword.fetch!(config, :namespace) do
      namespace when is_binary(namespace) and namespace != "" -> namespace
    end
  end

  defp attached_gateway_ids(%{id: id}) do
    AccessRoute
    |> Ash.Query.filter(instance_id == ^id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.gateway_id)
  end

  defp truncate(nil, _limit), do: nil

  defp truncate(message, limit) when is_binary(message) do
    message
    |> String.codepoints()
    |> Enum.take(limit)
    |> Enum.join()
  end

  # --- the workload spec builders (two writers, one source) ----------
  #
  # #493: the resize re-applies quota + PVC + deployment at the new
  # footprint, so the specs live here beside network_policy_spec — the
  # sanctioned shared seam. Callers: `DeployInstance` at deploy,
  # `ResizeInstance` at the resize re-apply.

  @env_secret "app-env"

  # Sidecar requests (ADR-0035): platform overhead on top of the
  # purchased allocation — the quota widens by exactly this (limits
  # ride the builders' 2x-requests convention). Decimal, not float:
  # the quota addition must not round (see quota_spec).
  @sidecar_cpu Decimal.new("0.05")
  @sidecar_memory_mb 64

  @doc """
  The namespace ResourceQuota spec for an instance's allocation — app
  requests plus platform overhead (the file-access sidecar, a
  configured backup Job's margin), storage requests as-is. `{:error,
  reason}` only when the backup-margin read fails (the caller — deploy
  or resize — fails the apply on it, never applies a half quota).

  Called by `DeployInstance` (deploy) and `ResizeInstance` (re-apply).
  """
  @spec quota_spec(map()) ::
          {:ok, %{cpu: Decimal.t(), memory: integer(), storage: integer()}} | {:error, term()}
  def quota_spec(instance) do
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

  @doc """
  Creates the data PVC when the instance allocates storage (gb > 0);
  `{:ok, nil}` at zero — config-only apps have no volume. SSA, so a
  re-apply converges.

  Called by `DeployInstance` (deploy) and `ResizeInstance` (the 0→N
  grow arm — a claim that didn't exist yet; a widening PVC upserts
  instead, capability-gated).
  """
  @spec maybe_create_pvc(Kubereq.Kubeconfig.t(), String.t(), map()) ::
          {:ok, map() | nil} | {:error, FluxVale.Clients.K8s.Error.t()}
  def maybe_create_pvc(kubeconfig, namespace, %{storage_gb: gb}) when gb > 0 do
    PersistentVolumeClaim.create(kubeconfig, namespace, "app-data", %{size: "#{gb}Gi"})
  end

  def maybe_create_pvc(_kubeconfig, _namespace, _instance), do: {:ok, nil}

  @doc """
  The app Deployment spec for an instance + the env argument — image,
  port, resources, probes, the PVC mount when storage is allocated, and
  `env_from_secret` when `env` is non-empty. What `env` IS differs by
  caller, deliberately: `DeployInstance` passes the merged env it is
  about to write (catalog defaults under user values, plus the seeded
  URL/allowlist entries); `ResizeInstance` passes the LIVE app-env
  Secret's body as the envFrom witness — non-empty keeps the reference,
  so a seeded ROOT_URL can never be stripped by a re-apply, and a
  missing Secret never dangles one. (The Secret itself is the deploy's
  to create.)

  Called by `DeployInstance` (deploy) and `ResizeInstance` (re-apply).
  """
  @spec deployment_spec(map(), map()) :: map()
  def deployment_spec(instance, env) do
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
      env_from_secret: "file-access",
      storage_mount: mount_path,
      cpu: @sidecar_cpu,
      memory: @sidecar_memory_mb
    }
  end

  # File access is on (and has a volume to serve) only when the app
  # declared it AND the instance allocated storage — a file-access app
  # at 0 GB has nothing to mount, so the sidecar silently doesn't land
  # (the wizard allows 0 GB with only a heads-up, so this is an ordinary
  # outcome, not a crafted one; the instance page gates its panel the
  # same way). Public: the Secret/Service/sidecar decision is shared by
  # both writers (the spec builders here, DeployInstance's Secret +
  # dav Service).
  @doc false
  @spec file_access?(map()) :: boolean()
  def file_access?(%{file_access: true, storage_gb: gb}) when gb > 0, do: true
  def file_access?(_instance), do: false

  @doc """
  The file-access app config (ADR-0035) — the sidecar spec and the
  WebDAV Secret/Service builders (DeployInstance) read through here so
  the one config key feeds both writers.
  """
  @spec file_access_config() :: keyword()
  def file_access_config do
    Application.fetch_env!(:flux_vale, :file_access)
  end

  @spec file_access_config(atom()) :: term()
  def file_access_config(key), do: file_access_config()[key]

  defp storage_mount_path(%{storage_gb: gb, storage_mount_path: path}) when gb > 0, do: path
  defp storage_mount_path(_instance), do: nil

  defp pvc_name(%{storage_gb: gb}) when gb > 0, do: "app-data"
  defp pvc_name(_instance), do: nil

  # --- the file-access world + edge posture (two writers, one source) -
  #
  # The WebDAV sidecar's support objects (credential Secret, DAV
  # Service) and the edge arms a deploy lands. Callers: `DeployInstance`
  # at deploy, `ResizeInstance` at the 0→N storage crossing — the
  # crossing on a file-access app gains the sidecar, whose world a
  # deploy at gb=0 never minted.

  @file_secret "file-access"
  @dav_service "dav"

  # Get-or-create, never blind-apply: a retrying deploy or resize must
  # not rotate a credential the owner already configured rclone with —
  # the secret is the credential's home (ADR-0035's storage decision),
  # so an existing row IS the credential. READ FIRST is load-bearing.
  @doc """
  The file-access credential Secret (ADR-0035) — get-or-create: an
  existing Secret is the owner's rclone-configured credential and is
  never rotated. `{:ok, nil}` when the instance carries no file access.

  Called by `DeployInstance` (deploy) and `ResizeInstance` (the 0→N
  storage crossing).
  """
  @spec maybe_create_file_secret(Kubereq.Kubeconfig.t(), String.t(), map()) ::
          {:ok, map() | nil} | {:error, FluxVale.Clients.K8s.Error.t()}
  def maybe_create_file_secret(kubeconfig, namespace, instance) do
    if file_access?(instance) do
      case Secret.get_data(kubeconfig, namespace, @file_secret) do
        {:ok, _existing} -> {:ok, nil}
        {:error, error} -> create_file_secret(kubeconfig, namespace, error)
      end
    else
      {:ok, nil}
    end
  end

  defp create_file_secret(kubeconfig, namespace, error) do
    if match?(%{reason: :not_found}, error) do
      # rclone reads basic auth straight from these env vars (RCLONE_USER/
      # RCLONE_PASS are the env forms of serve's --user/--pass) — the
      # Secret lands them in the container via envFrom, no shell, no
      # command-line exposure of the password.
      data = %{
        "RCLONE_USER" => file_access_config(:username),
        "RCLONE_PASS" => credential_password()
      }

      Secret.create(kubeconfig, namespace, @file_secret, data)
    else
      {:error, error}
    end
  end

  # 32 bytes of CSPRNG entropy, URL-safe base64 (43 chars): rclone
  # accepts any string; this keeps it copy-paste safe for rclone config.
  defp credential_password do
    entropy = :crypto.strong_rand_bytes(32)
    Base.url_encode64(entropy, padding: false)
  end

  @doc """
  The WebDAV Service (ADR-0035) — own Service so the app's Service stays
  untouched; the /dav route itself is EdgeRoutes'. `{:ok, nil}` when the
  instance carries no file access.

  Called by `DeployInstance` (deploy) and `ResizeInstance` (the 0→N
  storage crossing).
  """
  @spec maybe_create_dav_service(Kubereq.Kubeconfig.t(), String.t(), map()) ::
          {:ok, map() | nil} | {:error, FluxVale.Clients.K8s.Error.t()}
  def maybe_create_dav_service(kubeconfig, namespace, instance) do
    if file_access?(instance) do
      Service.create(kubeconfig, namespace, @dav_service, dav_service_spec())
    else
      {:ok, nil}
    end
  end

  # The WebDAV route rides the instance hostname under the path prefix
  # (Host(`slug.domain`) && PathPrefix(`/dav`) — Traefik auto-prioritizes
  # the longer match above the app's bare Host rule).
  defp dav_service_spec do
    %{
      port: 80,
      target_port: file_access_config(:port),
      selector: %{"app.kubernetes.io/name" => "app"}
    }
  end

  @doc """
  The edge posture a deploy lands — serving routes now, the access
  arms for an attached private row, dormant wake targets alongside (the
  first sleep must only rewrite a route Traefik already watches). A
  private row converges on no public routes — EdgeRoutes' own logic,
  never re-implemented here.

  Called by `DeployInstance` (deploy) and `ResizeInstance` (the 0→N
  storage crossing).
  """
  @spec apply_edge(Kubereq.Kubeconfig.t(), Instance.t()) ::
          :ok | {:error, term()}
  def apply_edge(kubeconfig, instance) do
    with :ok <- EdgeRoutes.apply_serving(kubeconfig, instance),
         :ok <- maybe_access_serving(kubeconfig, instance) do
      maybe_wake_targets(kubeconfig, instance)
    end
  end

  defp maybe_wake_targets(_kubeconfig, %{exposure: :private}), do: :ok

  defp maybe_wake_targets(kubeconfig, instance),
    do: EdgeRoutes.ensure_wake_targets(kubeconfig, instance)

  # S2 (ADR-0040 §7): an attached private instance's apply mints its
  # access arms alongside the (empty) public posture — the dispatch
  # lives inside the exposure branches so callers stay exposure-blind.
  # The arm follows the row's CURRENT status via the one owner (a
  # redeploy of a sleeping instance lands wake, not a stale serving
  # set); the dormant targets ride along either way.
  defp maybe_access_serving(kubeconfig, %{exposure: :private} = instance) do
    instance_id = instance.id

    # The pairing row is the durable record of "attached" (the policy
    # spec's own source). A read that fails is an error tuple — the
    # caller's failure arm owns those; a DB blip is not "unattached".
    case AccessRoute
         |> Ash.Query.filter(instance_id == ^instance_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        # Unattached private is panel-only (#265): no hostnames serve
        # anywhere, nothing to mint.
        :ok

      {:ok, route} ->
        with {:ok, route} <- Ash.load(route, :gateway, authorize?: false) do
          EdgeRoutes.apply_access_for_status(kubeconfig, route.gateway, instance)
        end

      {:error, _reason} = error ->
        # coveralls-ignore-start - defensive: a DB read failure (the
        # outage ExUnit cannot stage — DBConnection reconnects) is an
        # error tuple for the caller's failure arm, never a silent
        # "unattached".
        error
        # coveralls-ignore-stop
    end
  end

  defp maybe_access_serving(_kubeconfig, _public), do: :ok
end
