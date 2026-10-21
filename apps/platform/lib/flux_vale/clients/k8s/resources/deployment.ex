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

  Resource limits are 2x the requests — burst headroom, predictable cost.
  Probes (`probe_path`) come from `AppVersion.healthcheck_path` (#73).
  """

  alias FluxVale.Clients.K8s.Error

  require Logger

  @typedoc "Simplified deployment specification"
  @type spec :: %{
          required(:image) => String.t(),
          required(:port) => integer(),
          optional(:cpu) => float(),
          optional(:memory) => integer(),
          optional(:env) => map(),
          optional(:replicas) => integer(),
          optional(:storage_mount) => String.t(),
          optional(:pvc_name) => String.t(),
          optional(:probe_path) => String.t(),
          optional(:env_from_secret) => String.t(),
          optional(:sidecar) => sidecar_spec()
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

  @default_cpu 0.5
  @default_memory 256
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
  @spec restart(Kubereq.Kubeconfig.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  # v1-ported: same force-apply caveat as scale/4 — targeted patch when #73
  # wires callers.
  def restart(kubeconfig, namespace, name) do
    case get(kubeconfig, namespace, name) do
      {:ok, deployment} ->
        restart_at = DateTime.to_iso8601(DateTime.utc_now())

        updated =
          deployment
          |> strip_managed_fields()
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

    pod_spec =
      if volumes == [],
        do: %{"containers" => containers},
        else: %{"containers" => containers, "volumes" => volumes}

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
