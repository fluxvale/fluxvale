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
        pvc_name: "storage"              # Optional: PVC to mount (with storage_mount)
      }

  Resource limits are 2x the requests — burst headroom, predictable cost.
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
          optional(:pvc_name) => String.t()
        }

  @default_cpu 0.5
  @default_memory 256
  @default_replicas 1

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

      {:ok, %{status: 404}} ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}

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

      {:ok, %{status: 404}} ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Gets the deployment status: `%{replicas, actual_replicas, available, ready, conditions}`.
  """
  @spec status(Kubereq.Kubeconfig.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def status(kubeconfig, namespace, name) do
    case get(kubeconfig, namespace, name) do
      {:ok, deployment} ->
        {:ok,
         %{
           replicas: get_in(deployment, ["spec", "replicas"]) || 0,
           actual_replicas: get_in(deployment, ["status", "replicas"]) || 0,
           available: get_in(deployment, ["status", "availableReplicas"]) || 0,
           ready: get_in(deployment, ["status", "readyReplicas"]) || 0,
           conditions: get_in(deployment, ["status", "conditions"]) || []
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Scales a deployment to the given replica count."
  @spec scale(Kubereq.Kubeconfig.t(), String.t(), String.t(), integer()) ::
          {:ok, map()} | {:error, Error.t()}
  # v1-ported: get → strip managedFields → force-apply. The force flag makes
  # manager "fluxvale" claim every field of the fetched object, and the
  # get→apply window is last-write-wins. No v2 caller yet — #73's triggers
  # own the callers and should switch to a targeted patch on spec.replicas.
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
  reconciler, never by blocking the caller.
  """
  @spec wait_for_ready(Kubereq.Kubeconfig.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def wait_for_ready(kubeconfig, namespace, name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 60_000)
    interval = Keyword.get(opts, :poll_interval_ms, 1_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_for_ready(kubeconfig, namespace, name, deadline, interval)
  end

  # Polling an external resource, not a process — Process.sleep is the tool.
  defp do_wait_for_ready(kubeconfig, namespace, name, deadline, interval) do
    case status(kubeconfig, namespace, name) do
      {:ok, %{replicas: desired, ready: ready}} when ready >= desired and desired > 0 ->
        :ok

      {:ok, %{replicas: 0}} ->
        :ok

      {:ok, status} ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          {:error,
           Error.timeout(
             "Timeout waiting for deployment #{namespace}/#{name} to be ready. " <>
               "Status: #{inspect(status)}"
           )}
        else
          Process.sleep(interval)
          do_wait_for_ready(kubeconfig, namespace, name, deadline, interval)
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Builds the full Deployment manifest from the simplified spec.
  """
  @spec build_manifest(String.t(), String.t(), spec()) :: map()
  def build_manifest(namespace, name, spec) do
    cpu = Map.get(spec, :cpu, @default_cpu)
    memory = Map.get(spec, :memory, @default_memory)
    replicas = Map.get(spec, :replicas, @default_replicas)
    image = spec.image
    port = spec.port
    env = Map.get(spec, :env, %{})

    env_vars = Enum.map(env, fn {key, value} -> %{"name" => key, "value" => to_string(value)} end)

    container = %{
      "name" => "app",
      "image" => image,
      "ports" => [%{"containerPort" => port}],
      "resources" => %{
        "requests" => %{"cpu" => to_string(cpu), "memory" => "#{memory}Mi"},
        "limits" => %{"cpu" => to_string(cpu * 2), "memory" => "#{memory * 2}Mi"}
      },
      "env" => env_vars,
      "readinessProbe" => build_readiness_probe(port),
      "startupProbe" => build_startup_probe(port)
    }

    storage_mount = Map.get(spec, :storage_mount)
    pvc_name = Map.get(spec, :pvc_name)
    mount = if storage_mount && pvc_name, do: %{"name" => "storage", "mountPath" => storage_mount}

    app_container = if mount, do: Map.put(container, "volumeMounts", [mount]), else: container

    volumes =
      if storage_mount && pvc_name,
        do: [%{"name" => "storage", "persistentVolumeClaim" => %{"claimName" => pvc_name}}],
        else: []

    pod_spec =
      if volumes == [],
        do: %{"containers" => [app_container]},
        else: %{"containers" => [app_container], "volumes" => volumes}

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
        "replicas" => replicas,
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

  @doc false
  @spec build_readiness_probe(integer()) :: map()
  def build_readiness_probe(port) do
    %{
      "httpGet" => %{"path" => "/", "port" => port},
      "periodSeconds" => 5,
      "failureThreshold" => 3
    }
  end

  @doc false
  @spec build_startup_probe(integer()) :: map()
  def build_startup_probe(port) do
    %{
      "httpGet" => %{"path" => "/", "port" => port},
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
