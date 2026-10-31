defmodule FluxVale.Clients.K8s.Resources.ConfigMap do
  @moduledoc """
  CRUD operations for Kubernetes ConfigMaps.

  Today's only consumer is the access-DNS renderer (ADR-0040 §4): the
  fleet's CoreDNS deployment (fleet #122) mounts the zones ConfigMap the
  platform renders — the same "routing table as a mounted object the
  platform writes" posture as the gateway's serve-config Secret.

  Values are stored verbatim (ConfigMap data is plaintext by nature;
  never put a credential in one).
  """

  alias FluxVale.Clients.K8s.Error

  require Logger

  @typedoc "Simplified ConfigMap specification — string keys, string values."
  @type data :: %{optional(String.t()) => String.t()}

  @doc """
  Creates or server-side-applies a ConfigMap. SSA makes re-renders
  converge (a changed Corefile updates the mounted key; CoreDNS's
  config watch picks it up).
  """
  @spec create(Kubereq.Kubeconfig.t(), String.t(), String.t(), data(), %{
          optional(String.t()) => String.t()
        }) :: {:ok, map()} | {:error, Error.t()}
  def create(kubeconfig, namespace, name, data, extra_labels \\ %{}) do
    req = create_req(kubeconfig)
    manifest = build_manifest(namespace, name, data, extra_labels)

    case Kubereq.apply(req, manifest, "fluxvale") do
      {:ok, %{status: 201, body: body}} ->
        Logger.debug("Created configmap: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        Logger.debug("Updated configmap: #{namespace}/#{name}")
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Builds a ConfigMap manifest: `managed-by` label merged with `extra_labels`.
  """
  @spec build_manifest(String.t(), String.t(), data(), %{optional(String.t()) => String.t()}) ::
          map()
  def build_manifest(namespace, name, data, extra_labels \\ %{}) do
    %{
      "apiVersion" => "v1",
      "kind" => "ConfigMap",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "labels" =>
          Map.merge(
            %{
              "app.kubernetes.io/managed-by" => "fluxvale",
              "app.kubernetes.io/name" => name
            },
            extra_labels
          )
      },
      "data" => Map.new(data, fn {key, value} -> {key, to_string(value)} end)
    }
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(), kubeconfig: kubeconfig, api_version: "v1", kind: "ConfigMap")
  end
end
