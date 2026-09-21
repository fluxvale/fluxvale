defmodule FluxVale.Clients.K8s.Resources.PersistentVolumeClaim do
  @moduledoc """
  CRUD operations for Kubernetes PersistentVolumeClaims.

  PVCs carry customer app data (e.g. Forgejo's SQLite-on-PVC, ADR-0031) on
  the cluster's default StorageClass.

  ## Simplified Spec Format

      %{
        size: "1Gi",                  # Required: storage size (e.g., "1Gi", "500Mi")
        access_mode: "ReadWriteOnce"  # Optional: default is ReadWriteOnce
      }

  Resizing only supports increases, not decreases.
  """

  alias FluxVale.Clients.K8s.Error

  require Logger

  @typedoc "Simplified PVC specification"
  @type spec :: %{
          required(:size) => String.t(),
          optional(:access_mode) => String.t()
        }

  @default_access_mode "ReadWriteOnce"

  @doc "Creates (server-side-applies) a PVC."
  @spec create(Kubereq.Kubeconfig.t(), String.t(), String.t(), spec()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(kubeconfig, namespace, name, spec) do
    req = create_req(kubeconfig)
    manifest = build_manifest(namespace, name, spec)

    case Kubereq.apply(req, manifest, "fluxvale") do
      {:ok, %{status: 201, body: body}} ->
        Logger.debug("Created PVC: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Updated PVC: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc "Gets a PVC by namespace and name."
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

  @doc "Upserts a PVC — size increases only (resize)."
  @spec upsert(Kubereq.Kubeconfig.t(), String.t(), String.t(), spec()) ::
          {:ok, map()} | {:error, Error.t()}
  def upsert(kubeconfig, namespace, name, spec) do
    create(kubeconfig, namespace, name, spec)
  end

  @doc "Deletes a PVC — the data goes with it."
  @spec delete(Kubereq.Kubeconfig.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(kubeconfig, namespace, name) do
    req = create_req(kubeconfig)

    case Kubereq.delete(req, namespace, name) do
      {:ok, %{status: 200}} ->
        Logger.debug("Deleted PVC: #{namespace}/#{name}")
        :ok

      {:ok, %{status: 202}} ->
        Logger.debug("PVC deletion initiated: #{namespace}/#{name}")
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
  Gets the PVC phase: `"Pending"`, `"Bound"`, `"Lost"`, or `nil`.
  """
  @spec status(Kubereq.Kubeconfig.t(), String.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, Error.t()}
  def status(kubeconfig, namespace, name) do
    case get(kubeconfig, namespace, name) do
      {:ok, pvc} -> {:ok, get_in(pvc, ["status", "phase"])}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Polls until the PVC is `"Bound"` (default 120s / 2s interval).
  """
  @spec wait_for_bound(Kubereq.Kubeconfig.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def wait_for_bound(kubeconfig, namespace, name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 120_000)
    interval = Keyword.get(opts, :poll_interval_ms, 2_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_for_bound(kubeconfig, namespace, name, deadline, interval)
  end

  # Polling an external resource, not a process — Process.sleep is the tool.
  defp do_wait_for_bound(kubeconfig, namespace, name, deadline, interval) do
    case status(kubeconfig, namespace, name) do
      {:ok, "Bound"} ->
        :ok

      {:ok, status} ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          {:error,
           Error.timeout(
             "Timeout waiting for PVC #{namespace}/#{name} to be bound. " <>
               "Status: #{status || "unknown"}"
           )}
        else
          Process.sleep(interval)
          do_wait_for_bound(kubeconfig, namespace, name, deadline, interval)
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Builds the PVC manifest from the simplified spec."
  @spec build_manifest(String.t(), String.t(), spec()) :: map()
  def build_manifest(namespace, name, spec) do
    %{
      "apiVersion" => "v1",
      "kind" => "PersistentVolumeClaim",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "labels" => %{
          "app.kubernetes.io/managed-by" => "fluxvale",
          "app.kubernetes.io/name" => name
        }
      },
      "spec" => %{
        "accessModes" => [Map.get(spec, :access_mode, @default_access_mode)],
        "resources" => %{"requests" => %{"storage" => spec.size}}
      }
    }
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(),
      kubeconfig: kubeconfig,
      api_version: "v1",
      kind: "PersistentVolumeClaim"
    )
  end
end
