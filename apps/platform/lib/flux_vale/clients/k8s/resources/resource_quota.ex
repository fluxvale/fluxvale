defmodule FluxVale.Clients.K8s.Resources.ResourceQuota do
  @moduledoc """
  CRUD operations for Kubernetes ResourceQuotas.

  A quota per instance namespace is a product primitive (ADR-0005): the
  namespace's total spend is capped at the instance's allocation, so a
  misbehaving app can't starve neighbors — the Deployment's requests fit
  exactly (limits are 2x requests, and the quota's limits match).

  ## Simplified Spec Format

      %{
        cpu: 0.5,        # Required: CPU cores (namespace request cap)
        memory: 256,     # Required: memory in MB (namespace request cap)
        storage: 10      # Required: storage in GB (PVC request cap)
      }

  The quota hard-caps `limits.cpu/memory` at 2x the request caps,
  mirroring the per-container limit headroom
  (`FluxVale.Clients.K8s.Resources.Deployment`).
  """

  alias FluxVale.Clients.K8s.Error

  require Logger

  @typedoc "Simplified resource quota specification"
  @type spec :: %{
          required(:cpu) => float(),
          required(:memory) => integer(),
          required(:storage) => integer()
        }

  @doc "Creates (server-side-applies) a ResourceQuota from a simplified spec."
  @spec create(Kubereq.Kubeconfig.t(), String.t(), String.t(), spec()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(kubeconfig, namespace, name, spec) do
    req = create_req(kubeconfig)
    manifest = build_manifest(namespace, name, spec)

    case Kubereq.apply(req, manifest, "fluxvale") do
      {:ok, %{status: 201, body: body}} ->
        Logger.debug("Created resource quota: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Updated resource quota: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc "Gets a ResourceQuota by namespace and name."
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

  @doc "Deletes a ResourceQuota."
  @spec delete(Kubereq.Kubeconfig.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(kubeconfig, namespace, name) do
    req = create_req(kubeconfig)

    case Kubereq.delete(req, namespace, name) do
      {:ok, %{status: 200}} ->
        Logger.debug("Deleted resource quota: #{namespace}/#{name}")
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
  Builds the ResourceQuota manifest from the simplified spec.
  """
  @spec build_manifest(String.t(), String.t(), spec()) :: map()
  def build_manifest(namespace, name, spec) do
    cpu = spec.cpu
    memory = spec.memory
    storage = spec.storage

    %{
      "apiVersion" => "v1",
      "kind" => "ResourceQuota",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "labels" => %{
          "app.kubernetes.io/managed-by" => "fluxvale",
          "app.kubernetes.io/name" => name
        }
      },
      "spec" => %{
        "hard" => %{
          "requests.cpu" => to_string(cpu),
          "requests.memory" => "#{memory}Mi",
          "limits.cpu" => to_string(cpu * 2),
          "limits.memory" => "#{memory * 2}Mi",
          "requests.storage" => "#{storage}Gi",
          "persistentvolumeclaims" => "1"
        }
      }
    }
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(), kubeconfig: kubeconfig, api_version: "v1", kind: "ResourceQuota")
  end
end
