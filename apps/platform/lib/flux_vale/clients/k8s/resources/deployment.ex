defmodule FluxVale.Clients.K8s.Resources.Deployment do
  @moduledoc """
  CRUD + lifecycle operations for Kubernetes Deployments.

  Deployments run the customer app container in an Instance's namespace.

  ## Simplified Spec Format

      %{
        image: "nginx:alpine",           # Required: container image
        port: 80,                        # Required: container port
        cpu: 0.5,                        # Optional: CPU cores (default: 0.5)
        memory: 256,                     # Optional: Memory in MB (default: 256)
        env: %{"KEY" => "value"},        # Optional: environment variables
        replicas: 1,                     # Optional: replica count (default: 1)
        storage_mount: "/data",          # Optional: PVC mount path
        pvc_name: "storage",             # Optional: PVC to mount (with storage_mount)
        probe_path: "/api/healthz",      # Optional: probe path (default: "/")
        env_from_secret: "app-env",      # Optional: Secret consumed via envFrom
        sidecar: %{...}                  # Optional: one extra container (below)
      }

  `sidecar` (#190, ADR-0035) adds one platform-owned container to the
  pod — the file-access WebDAV server sharing the app's data volume:

      %{
        image: "rclone/rclone:1.75.2",   # Required
        port: 8080,                      # Required: container port (no probe)
        args: ["serve", ...],            # Required: argv after the entrypoint
        env_from_secret: "file-access",  # Required: Secret consumed via envFrom
        storage_mount: "/data",          # Required: same PVC mount as the app
        cpu: 0.05,                       # Required: requests (limits = 2x, like the app)
        memory: 64                       # Required: requests in MB
      }

  The sidecar mounts the same `storage` volume as the app container and
  carries no probes — pod readiness is the app container's contract
  (the reconciler's semantics stay unchanged).

  `backing_services` (#612, ADR-0045) adds native-sidecar init
  containers — the instance's bundled Postgres/Redis, rendered in list
  order before every regular container:

      %{
        kind: :postgres,                 # Required: :postgres | :redis (shape source)
        image: "postgres:18.6-alpine3.24", # Required: the instance's pinned ref
        port: 5432,                      # Required: container/probe port
        env_from_secret: "backing-services", # Required: credentials + URLs
        cpu: 0.10,                       # Required: requests (limits = 2x)
        memory_mb: 256                   # Required: requests in MB
      }

  Kind owns the container shape: postgres gets
  `listen_addresses=127.0.0.1` args + PGDATA below its mount; redis
  gets a requirepass-from-env command. Both bind loopback only, probe
  readiness with the engine's own client (`pg_isready -h 127.0.0.1` —
  the `-h` is load-bearing: a bare probe would pass against the
  socket-only initdb server; `redis-cli ping` via `REDISCLI_AUTH`),
  mount `backing/<kind>` subPaths of the shared `storage` volume, and
  carry `restartPolicy: Always` — native-sidecar semantics gate the
  next init container (and thus the app container) on probe success.
  No secret lands in the pod spec: credentials ride envFrom.

  Resource limits are 2x the requests — burst headroom, predictable cost.
  Probes (`probe_path`) come from `AppVersion.healthcheck_path` (#73).
  """

  alias FluxVale.Clients.K8s.Error

  require Logger

  @typedoc "Simplified deployment specification"
  @type spec :: %{
          required(:image) => String.t(),
          required(:port) => integer(),
          # Decimal accepted (#612): the app's requests are carved from
          # the allocation — float would round (the sidecar's stance).
          optional(:cpu) => float() | Decimal.t(),
          optional(:memory) => integer(),
          optional(:env) => map(),
          optional(:replicas) => integer(),
          optional(:storage_mount) => String.t(),
          optional(:pvc_name) => String.t(),
          optional(:probe_path) => String.t(),
          optional(:env_from_secret) => String.t(),
          optional(:sidecar) => sidecar_spec(),
          optional(:backing_services) => [backing_service_spec()]
        }

  @typedoc "One platform-owned extra container in the pod (#190)"
  @type sidecar_spec :: %{
          required(:image) => String.t(),
          required(:port) => integer(),
          required(:args) => [String.t()],
          required(:env_from_secret) => String.t(),
          required(:storage_mount) => String.t(),
          # Decimal accepted (#190): sidecar requests add to exact
          # allocations — float would round (see ResourceQuota's spec).
          required(:cpu) => float() | Decimal.t(),
          required(:memory) => integer()
        }

  @typedoc """
  One bundled backing service as a native-sidecar init container
  (#612, ADR-0045). Rendered in list order; `kind` owns the container
  shape. Decimal cpu for the same exactness reason as the sidecar —
  the requests are carved from the purchased allocation.
  """
  @type backing_service_spec :: %{
          required(:kind) => :postgres | :redis,
          required(:image) => String.t(),
          required(:port) => integer(),
          required(:env_from_secret) => String.t(),
          required(:cpu) => float() | Decimal.t(),
          required(:memory_mb) => integer()
        }

  @default_cpu 0.5
  @default_memory 256

  # The supplemental gid every volume-mounting pod grants (see
  # build_manifest's securityContext comment).
  @volume_fs_group 2000
  @default_replicas 1
  @default_probe_path "/"

  @doc """
  Creates (server-side-applies) a Deployment from a simplified spec.
  """
  @spec create(Kubereq.Kubeconfig.t(), String.t(), String.t(), spec()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(kubeconfig, namespace, name, spec) do
    req = create_req(kubeconfig)
    manifest = build_manifest(namespace, name, spec)

    case Kubereq.apply(req, manifest, "fluxvale") do
      {:ok, %{status: 201, body: body}} ->
        Logger.info("Created deployment: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Updated deployment: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Server-side-applies a caller-built Deployment manifest verbatim.

  The escape hatch for pods that are not customer apps — today the access
  gateway (ADR-0039 §1), whose shape the app builder cannot express: its
  probes are its own health port (9002, not the app's port), its auth key
  is a `secretKeyRef` rather than `envFrom`, and it mounts two volumes. Keeping the manifest
  in the provider that owns the pod (and Kubereq in this module) beats
  teaching an app-shaped builder a second dialect.
  """
  @spec apply_manifest(Kubereq.Kubeconfig.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def apply_manifest(kubeconfig, manifest) do
    req = create_req(kubeconfig)

    case Kubereq.apply(req, manifest, "fluxvale") do
      {:ok, %{status: status, body: body}} when status in [200, 201] ->
        Logger.info(
          "Applied deployment manifest: #{get_in(manifest, ["metadata", "namespace"])}/" <>
            "#{get_in(manifest, ["metadata", "name"])}"
        )

        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc "Gets a deployment by namespace and name."
  @spec get(Kubereq.Kubeconfig.t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(kubeconfig, namespace, name) do
    req = create_req(kubeconfig)

    case Kubereq.get(req, namespace, name) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404, body: body}} ->
        {:error, Error.from_response({:ok, %{status: 404, body: body}})}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc "Upserts a deployment — SSA, idempotent."
  @spec upsert(Kubereq.Kubeconfig.t(), String.t(), String.t(), spec()) ::
          {:ok, map()} | {:error, Error.t()}
  def upsert(kubeconfig, namespace, name, spec) do
    create(kubeconfig, namespace, name, spec)
  end

  @doc "Deletes a deployment."
  @spec delete(Kubereq.Kubeconfig.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(kubeconfig, namespace, name) do
    req = create_req(kubeconfig)

    case Kubereq.delete(req, namespace, name) do
      {:ok, %{status: 200}} ->
        Logger.debug("Deleted deployment: #{namespace}/#{name}")
        :ok

      {:ok, %{status: 202}} ->
        Logger.debug("Deployment deletion initiated: #{namespace}/#{name}")
        :ok

      {:ok, %{status: 404, body: body}} ->
        {:error, Error.from_response({:ok, %{status: 404, body: body}})}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Gets the deployment status:

      %{replicas, actual_replicas, updated, available, ready,
        generation, observed_generation, conditions}

  `generation`/`observed_generation` matter after any apply that changes the
  pod template — `readyReplicas` alone can report *old* pods as ready until
  the controller rolls the new generation.
  """
  @spec status(Kubereq.Kubeconfig.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def status(kubeconfig, namespace, name) do
    case get(kubeconfig, namespace, name) do
      {:ok, deployment} -> {:ok, build_status(deployment)}
      {:error, error} -> {:error, error}
    end
  end

  defp build_status(deployment) do
    # spec.replicas is API-defaulted to 1 at admission; nil → 0 reads as
    # ready (scale-to-zero) — unreachable via GET, defensive only.
    %{
      replicas: get_in(deployment, ["spec", "replicas"]) || 0,
      actual_replicas: get_in(deployment, ["status", "replicas"]) || 0,
      updated: get_in(deployment, ["status", "updatedReplicas"]) || 0,
      available: get_in(deployment, ["status", "availableReplicas"]) || 0,
      ready: get_in(deployment, ["status", "readyReplicas"]) || 0,
      generation: get_in(deployment, ["metadata", "generation"]) || 0,
      observed_generation: get_in(deployment, ["status", "observedGeneration"]) || 0,
      conditions: get_in(deployment, ["status", "conditions"]) || []
    }
  end

  @doc "Scales a deployment to the given replica count."
  @spec scale(Kubereq.Kubeconfig.t(), String.t(), String.t(), integer()) ::
          {:ok, map()} | {:error, Error.t()}
  # v1-ported: get → strip managedFields → force-apply. The force flag makes
  # manager "fluxvale" claim every field of the fetched object, and the
  # get→apply window is last-write-wins — tolerable inside instance
  # namespaces, where fluxvale is the only writer (stop/start, #73). A
  # targeted patch on spec.replicas is the future refinement.
  def scale(kubeconfig, namespace, name, replicas) when is_integer(replicas) and replicas >= 0 do
    case get(kubeconfig, namespace, name) do
      {:ok, deployment} ->
        # managedFields must go — Kubernetes rejects them in apply operations
        updated =
          deployment
          |> strip_managed_fields()
          |> put_in(["spec", "replicas"], replicas)

        req = create_req(kubeconfig)

        case Kubereq.apply(req, updated, "fluxvale") do
          {:ok, %{status: 200, body: body}} ->
            Logger.debug("Scaled deployment #{namespace}/#{name} to #{replicas} replicas")
            {:ok, body}

          {:ok, %{status: status, body: body}} ->
            {:error, Error.from_response({:ok, %{status: status, body: body}})}

          {:error, error} ->
            {:error, Error.from_response({:error, error})}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Rolling restart via the pod-template annotation."
  @spec restart(Kubereq.Kubeconfig.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  # v1-ported: same force-apply caveat as scale/4 — targeted patch when #73
  # wires callers.
  #
  # `ensure_env_from`: after the GET/strip, add the Secret to the APP
  # container's envFrom when absent (idempotent; sidecars untouched).
  # The first-ever env write on a deployment created without `app-env`
  # needs this — an annotation bump alone would roll an unchanged pod
  # template and the app would never read the Secret.
  def restart(kubeconfig, namespace, name, opts \\ []) do
    case get(kubeconfig, namespace, name) do
      {:ok, deployment} ->
        restart_at = DateTime.to_iso8601(DateTime.utc_now())

        updated =
          deployment
          |> strip_managed_fields()
          |> ensure_env_from(Keyword.get(opts, :ensure_env_from))
          |> update_in(["spec", "template", "metadata", "annotations"], fn
            nil -> %{"fluxvale.io/restartedAt" => restart_at}
            ann -> Map.put(ann, "fluxvale.io/restartedAt", restart_at)
          end)

        req = create_req(kubeconfig)

        case Kubereq.apply(req, updated, "fluxvale") do
          {:ok, %{status: 200, body: body}} ->
            Logger.debug("Restarted deployment: #{namespace}/#{name}")
            {:ok, body}

          {:ok, %{status: status, body: body}} ->
            {:error, Error.from_response({:ok, %{status: status, body: body}})}

          {:error, error} ->
            {:error, Error.from_response({:error, error})}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  # Only the app container consumes the instance env; sidecars and the
  # backing-service containers keep their own envFrom lists.
  defp ensure_env_from(deployment, nil), do: deployment

  defp ensure_env_from(deployment, secret_name) do
    update_in(deployment, ["spec", "template", "spec", "containers"], fn
      nil ->
        nil

      containers ->
        Enum.map(containers, fn
          %{"name" => "app"} = container -> put_env_from(container, secret_name)
          container -> container
        end)
    end)
  end

  defp put_env_from(container, secret_name) do
    env_from = Map.get(container, "envFrom") || []

    if Enum.any?(env_from, &match?(%{"secretRef" => %{"name" => ^secret_name}}, &1)) do
      container
    else
      Map.put(container, "envFrom", env_from ++ [%{"secretRef" => %{"name" => secret_name}}])
    end
  end

  @doc """
  Polls until the deployment has its desired ready replicas.

  Used by local-cluster integration work (#73) to synchronize on real-cluster
  readiness — production reflects readiness asynchronously via the status
  reconciler, never by blocking the caller. A **paused** deployment never
  becomes ready (`observedGeneration` stalls) — correct "not ready", but
  expect the timeout.
  """
  @spec wait_for_ready(Kubereq.Kubeconfig.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def wait_for_ready(kubeconfig, namespace, name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 60_000)
    interval = Keyword.get(opts, :poll_interval_ms, 1_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_for_ready(kubeconfig, namespace, name, deadline, interval)
  end

  @doc """
  Readiness predicate over a `status/3` map — the testable core of
  `wait_for_ready/4`.

  Gates on the generation handshake, not `readyReplicas` alone: after
  scale/restart/create apply a new generation, old pods can still satisfy
  `ready >= desired` until the controller rolls the update. Scale-to-zero
  (`replicas: 0`) is ready by definition.
  """
  @spec ready?(map()) :: boolean()
  def ready?(%{replicas: 0}), do: true

  def ready?(%{
        replicas: desired,
        actual_replicas: actual,
        updated: updated,
        ready: ready,
        generation: generation,
        observed_generation: observed
      }) do
    observed >= generation and updated == desired and actual == desired and ready >= desired
  end

  # Polling an external resource, not a process — Process.sleep is the tool.
  defp do_wait_for_ready(kubeconfig, namespace, name, deadline, interval) do
    case status(kubeconfig, namespace, name) do
      {:ok, status_map} ->
        if ready?(status_map) do
          :ok
        else
          retry_or_timeout(status_map, kubeconfig, namespace, name, deadline, interval)
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp retry_or_timeout(status_map, kubeconfig, namespace, name, deadline, interval) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error,
       Error.timeout(
         "Timeout waiting for deployment #{namespace}/#{name} to be ready. " <>
           "Status: #{inspect(status_map)}"
       )}
    else
      Process.sleep(interval)
      do_wait_for_ready(kubeconfig, namespace, name, deadline, interval)
    end
  end

  @doc """
  Builds the full Deployment manifest from the simplified spec.
  """
  @spec build_manifest(String.t(), String.t(), spec()) :: map()
  def build_manifest(namespace, name, spec) do
    storage_mount = Map.get(spec, :storage_mount)
    pvc_name = Map.get(spec, :pvc_name)

    app_container = build_app_container(spec)
    volumes = build_volumes(storage_mount, pvc_name)

    containers =
      case Map.get(spec, :sidecar) do
        nil -> [app_container]
        sidecar -> [app_container | [build_sidecar_container(sidecar)]]
      end

    # Native sidecars (#612, D8): rendered in the spec's list order —
    # each gates the next init container on its startup probe, and the
    # app container starts only after all of them.
    init_containers =
      spec
      |> Map.get(:backing_services, [])
      |> Enum.map(&build_backing_init_container/1)

    # Volume writability for non-root images: the first such entry
    # (#609's Docmost, UID 1000) writing uploads to its PVC exposed
    # that the pod spec set no securityContext — a local-path volume
    # lands root-owned, so the app's writes EACCES (the local stack's
    # own MinIO manifest documents the same fix for its nonroot uid).
    # fsGroup rides the pod only when a volume actually mounts: the
    # kubelet grants the gid as a supplemental group with group-write
    # on the volume to EVERY container in the pod, so any image uid —
    # root, node, chainguard's 65532 — can write and uid-matching per
    # app stays out of catalog data. 2000 sits clear of the common
    # image gids (0 root, 70 postgres, 1000 node, 65532 nonroot).
    pod_security_context =
      if volumes == [],
        do: nil,
        else: %{"fsGroup" => @volume_fs_group}

    pod_spec =
      %{"containers" => containers}
      |> maybe_put_section("volumes", volumes)
      |> maybe_put_section("initContainers", init_containers)
      |> maybe_put_value("securityContext", pod_security_context)

    %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "labels" => %{
          "app.kubernetes.io/managed-by" => "fluxvale",
          "app.kubernetes.io/name" => name
        }
      },
      "spec" => %{
        "replicas" => Map.get(spec, :replicas, @default_replicas),
        "selector" => %{"matchLabels" => %{"app.kubernetes.io/name" => name}},
        "template" => %{
          "metadata" => %{
            "labels" => %{
              "app.kubernetes.io/managed-by" => "fluxvale",
              "app.kubernetes.io/name" => name
            }
          },
          "spec" => pod_spec
        }
      }
    }
  end

  defp maybe_put_section(pod_spec, _section, []), do: pod_spec

  defp maybe_put_section(pod_spec, section, entries),
    do: Map.put(pod_spec, section, entries)

  # nil drops the key entirely (the no-volume pod carries no
  # securityContext — nothing to grant write on).
  defp maybe_put_value(map, _key, nil), do: map

  defp maybe_put_value(map, key, value), do: Map.put(map, key, value)

  # The app container: image/port/resources from the spec, probes from
  # the healthcheck path, env from spec.env, user env via envFrom
  # Secret, storage mounted when a PVC is named. CPU is normalized to
  # Decimal (#190): Kernel arithmetic on a Decimal crashes, and the
  # doubling must be exact.
  @spec build_app_container(spec()) :: map()
  defp build_app_container(spec) do
    cpu = decimal_cpu(Map.get(spec, :cpu, @default_cpu))
    memory = Map.get(spec, :memory, @default_memory)
    probe_path = Map.get(spec, :probe_path, @default_probe_path)
    port = spec.port
    env = Map.get(spec, :env, %{})

    env_vars = Enum.map(env, fn {key, value} -> %{"name" => key, "value" => to_string(value)} end)

    {cpu_request, cpu_limit} = cpu_strings(cpu)

    base_container = %{
      "name" => "app",
      "image" => spec.image,
      "ports" => [%{"containerPort" => port}],
      "resources" => %{
        "requests" => %{"cpu" => cpu_request, "memory" => "#{memory}Mi"},
        "limits" => %{"cpu" => cpu_limit, "memory" => "#{memory * 2}Mi"}
      },
      "env" => env_vars,
      "readinessProbe" => build_readiness_probe(port, probe_path),
      "startupProbe" => build_startup_probe(port, probe_path)
    }

    # User env rides a Secret via envFrom (values stay out of the pod
    # spec) when the deployer provides one; spec.env stays for inline vars.
    with_env_from =
      case Map.get(spec, :env_from_secret) do
        nil ->
          base_container

        secret_name ->
          Map.put(base_container, "envFrom", [%{"secretRef" => %{"name" => secret_name}}])
      end

    storage_mount = Map.get(spec, :storage_mount)

    if Map.get(spec, :pvc_name) && storage_mount do
      mount = %{"name" => "storage", "mountPath" => storage_mount}
      Map.put(with_env_from, "volumeMounts", [mount])
    else
      with_env_from
    end
  end

  defp build_volumes(storage_mount, pvc_name) do
    if storage_mount && pvc_name,
      do: [%{"name" => "storage", "persistentVolumeClaim" => %{"claimName" => pvc_name}}],
      else: []
  end

  # The platform-owned file-access container (#190): same volume mount
  # as the app, env from its own Secret, no probes (readiness is the
  # app container's contract), limits 2x requests like the app.
  @spec build_sidecar_container(sidecar_spec()) :: map()
  defp build_sidecar_container(sidecar) do
    cpu = decimal_cpu(sidecar.cpu)
    {cpu_request, cpu_limit} = cpu_strings(cpu)

    %{
      "name" => "file-access",
      "image" => sidecar.image,
      "ports" => [%{"containerPort" => sidecar.port}],
      "args" => sidecar.args,
      "envFrom" => [%{"secretRef" => %{"name" => sidecar.env_from_secret}}],
      "resources" => %{
        "requests" => %{"cpu" => cpu_request, "memory" => "#{sidecar.memory}Mi"},
        "limits" => %{"cpu" => cpu_limit, "memory" => "#{sidecar.memory * 2}Mi"}
      },
      "volumeMounts" => [%{"name" => "storage", "mountPath" => sidecar.storage_mount}]
    }
  end

  # --- bundled backing services (#612, ADR-0045) ----------------------

  # One native-sidecar init container per declared service. Kind owns
  # the shape (listener binding, probe command, mount point); the spec
  # owns the pin. restartPolicy Always + a passing startup probe is
  # what orders the pod: the next init container (and the app) waits
  # on THIS container accepting connections.
  @spec build_backing_init_container(backing_service_spec()) :: map()
  defp build_backing_init_container(service) do
    cpu = decimal_cpu(service.cpu)
    {cpu_request, cpu_limit} = cpu_strings(cpu)

    container = %{
      "name" => Atom.to_string(service.kind),
      "image" => service.image,
      "ports" => [%{"containerPort" => service.port}],
      "envFrom" => [%{"secretRef" => %{"name" => service.env_from_secret}}],
      "resources" => %{
        "requests" => %{"cpu" => cpu_request, "memory" => "#{service.memory_mb}Mi"},
        "limits" => %{"cpu" => cpu_limit, "memory" => "#{service.memory_mb * 2}Mi"}
      },
      "restartPolicy" => "Always",
      "startupProbe" => backing_startup_probe(service.kind)
    }

    Map.merge(container, backing_kind_fields(service.kind))
  end

  # Loopback listeners (§4.3): the URL is `localhost` by design, so
  # "nothing is exposed outside the pod" holds at the LISTENER, not
  # just the network layer. Postgres: args after the image entrypoint
  # (docker-entrypoint.sh stays; the initdb temp server is socket-only
  # and unaffected). Redis: the official image has no env-based
  # requirepass, and a bare arg would put the password in the pod
  # spec — the shell expands $REDIS_PASSWORD at runtime instead.
  defp backing_kind_fields(:postgres) do
    %{
      "args" => ["postgres", "-c", "listen_addresses=127.0.0.1"],
      "env" => [
        # The image's lost+found quirk on volume roots: PGDATA below
        # the subPath mount, in its own subdir (§4.6).
        %{"name" => "PGDATA", "value" => "/var/lib/postgresql/data/pgdata"}
      ],
      "volumeMounts" => [
        %{
          "name" => "storage",
          "mountPath" => "/var/lib/postgresql/data",
          "subPath" => "backing/postgres"
        }
      ]
    }
  end

  defp backing_kind_fields(:redis) do
    %{
      "command" => [
        "sh",
        "-c",
        ~s|exec redis-server --requirepass "$REDIS_PASSWORD" | <>
          "--bind 127.0.0.1 --protected-mode yes"
      ],
      "volumeMounts" => [
        %{"name" => "storage", "mountPath" => "/data", "subPath" => "backing/redis"}
      ]
    }
  end

  # `pg_isready -h 127.0.0.1` (never a bare call): on first boot the
  # postgres image runs a socket-only temp server, and a socket probe
  # would pass before TCP 5432 listens — the app would race the real
  # DB. `redis-cli ping` authenticates through REDISCLI_AUTH (envFrom
  # above), so PONG means auth AND liveness. Thresholds: PG gets 3
  # minutes (initdb on a cold volume), Redis 1.
  defp backing_startup_probe(:postgres) do
    %{
      "exec" => %{"command" => ["pg_isready", "-h", "127.0.0.1"]},
      "periodSeconds" => 5,
      "failureThreshold" => 36
    }
  end

  defp backing_startup_probe(:redis) do
    %{
      "exec" => %{"command" => ["redis-cli", "ping"]},
      "periodSeconds" => 5,
      "failureThreshold" => 12
    }
  end

  # CPU as canonical quantity strings (#190): {request, 2x limit},
  # normalized — no scale artifacts ("0.50"), no Kernel arithmetic on
  # Decimal (crashes), no float addition (rounds).
  defp cpu_strings(cpu) do
    normalized = Decimal.normalize(cpu)

    limit =
      normalized
      |> Decimal.mult(2)
      |> Decimal.normalize()

    {Decimal.to_string(normalized), Decimal.to_string(limit)}
  end

  defp decimal_cpu(%Decimal{} = cpu), do: cpu
  defp decimal_cpu(cpu) when is_float(cpu), do: Decimal.from_float(cpu)

  @doc false
  @spec build_readiness_probe(integer(), String.t()) :: map()
  def build_readiness_probe(port, probe_path \\ @default_probe_path) do
    %{
      "httpGet" => %{"path" => probe_path, "port" => port},
      "periodSeconds" => 5,
      "failureThreshold" => 3
    }
  end

  @doc false
  @spec build_startup_probe(integer(), String.t()) :: map()
  def build_startup_probe(port, probe_path \\ @default_probe_path) do
    %{
      "httpGet" => %{"path" => probe_path, "port" => port},
      "periodSeconds" => 5,
      "failureThreshold" => 18
    }
  end

  # Strips server-managed fields before apply — K8s rejects managedFields.
  @spec strip_managed_fields(map()) :: map()
  defp strip_managed_fields(resource) when is_map(resource) do
    Map.update(resource, "metadata", %{}, fn meta -> Map.delete(meta, "managedFields") end)
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(), kubeconfig: kubeconfig, api_version: "apps/v1", kind: "Deployment")
  end
end
