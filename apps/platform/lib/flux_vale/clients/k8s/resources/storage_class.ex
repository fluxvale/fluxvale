defmodule FluxVale.Clients.K8s.Resources.StorageClass do
  @moduledoc """
  Read operations for Kubernetes StorageClasses.

  The PVC manifest sets no `storageClassName` — every claim lands on
  the cluster's default class — so volume expansion is that class's
  capability (`spec.allowVolumeExpansion`), not ours (#493). local-path
  answers false today; when the storage lane ships an expandable class
  (TopoLVM), the up-only resize policy self-unlocks through this probe.
  """

  alias FluxVale.Clients.K8s.Error

  @default_annotation "storageclass.kubernetes.io/is-default-class"

  @doc """
  Whether the cluster's default StorageClass allows volume expansion.
  No default class → `{:ok, false}` — nothing to expand. Multiple
  default-annotated classes → true if any of them expands (admission
  binds one; the generous read never blocks a legal grow).
  """
  @spec default_allows_expansion?(Kubereq.Kubeconfig.t()) ::
          {:ok, boolean()} | {:error, Error.t()}
  def default_allows_expansion?(kubeconfig) do
    case list(kubeconfig) do
      {:ok, classes} ->
        allowed =
          classes
          |> Enum.filter(&default_class?/1)
          |> Enum.any?(&allows_expansion?/1)

        {:ok, allowed}

      {:error, _reason} = error ->
        error
    end
  end

  defp default_class?(class) do
    get_in(class, ["metadata", "annotations", @default_annotation]) == "true"
  end

  defp allows_expansion?(class) do
    get_in(class, ["spec", "allowVolumeExpansion"]) == true
  end

  @spec list(Kubereq.Kubeconfig.t()) :: {:ok, list(map())} | {:error, Error.t()}
  defp list(kubeconfig) do
    req = create_req(kubeconfig)

    case Kubereq.list(req) do
      {:ok, %{status: 200, body: %{"items" => items}}} when is_list(items) ->
        {:ok, items}

      # Malformed 200 body — must not reach from_response/1 (raises on 2xx).
      {:ok, %{status: 200, body: body}} ->
        {:error, Error.validation_error("Malformed StorageClassList response: #{inspect(body)}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(),
      kubeconfig: kubeconfig,
      api_version: "storage.k8s.io/v1",
      kind: "StorageClass"
    )
  end
end
