defmodule FluxVale.Clients.K8s.Resources.Pod do
  @moduledoc """
  Read operations for Kubernetes Pods.

  Today's only consumer is the access-DNS renderer (ADR-0040 §4): a
  gateway view must answer with the gateway's CURRENT pod IP, and the
  pod's phase must be Running — a restarting gateway is dark for DNS
  until the next pass, the documented window.

  Listing is namespaced; the label selector is applied client-side (the
  access namespace holds only the platforms' own gateway pods — a
  handful — so a selector parameter would buy nothing).
  """

  alias FluxVale.Clients.K8s.Error

  @doc """
  Lists the namespace's pods carrying EVERY label in `labels`.
  `{:ok, pod_bodies}` or `{:error, Error.t()}`.
  """
  @spec list_by_labels(Kubereq.Kubeconfig.t(), String.t(), %{optional(String.t()) => String.t()}) ::
          {:ok, list(map())} | {:error, Error.t()}
  def list_by_labels(kubeconfig, namespace, labels) do
    req = create_req(kubeconfig)

    case Kubereq.list(req, namespace) do
      {:ok, %{status: 200, body: %{"items" => items}}} when is_list(items) ->
        {:ok, Enum.filter(items, &labeled?(&1, labels))}

      # Malformed 200 body — must not reach from_response/1 (raises on 2xx).
      {:ok, %{status: 200, body: body}} ->
        {:error, Error.validation_error("Malformed PodList response: #{inspect(body)}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  The pod's IP when it is Running, else nil (pending/succeeded/failed
  pods have no address worth routing to).
  """
  @spec running_ip(map()) :: String.t() | nil
  def running_ip(pod) do
    if get_in(pod, ["status", "phase"]) == "Running" do
      get_in(pod, ["status", "podIP"])
    end
  end

  @doc """
  True while the pod is terminating (`deletionTimestamp` set) — its IP
  is a reuse window (the address may already belong to the
  replacement), never a routing source.
  """
  @spec terminating?(map()) :: boolean()
  def terminating?(pod) do
    get_in(pod, ["metadata", "deletionTimestamp"]) != nil
  end

  @doc """
  The pod's `creationTimestamp` as a DateTime — the newest-survivor
  ordering key. Unparseable sorts oldest so a broken clock never wins.
  """
  @spec started_at(map()) :: DateTime.t()
  def started_at(pod) do
    case get_in(pod, ["metadata", "creationTimestamp"]) do
      stamp when is_binary(stamp) ->
        case DateTime.from_iso8601(stamp) do
          {:ok, dt, _offset} -> dt
          _unparseable -> ~U[1970-01-01 00:00:00Z]
        end

      _missing ->
        ~U[1970-01-01 00:00:00Z]
    end
  end

  defp labeled?(pod, labels) do
    pod_labels = get_in(pod, ["metadata", "labels"]) || %{}
    Map.to_list(labels) -- Map.to_list(pod_labels) == []
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(), kubeconfig: kubeconfig, api_version: "v1", kind: "Pod")
  end
end
