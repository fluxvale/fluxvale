defmodule FluxVale.Clients.K8s do
  @moduledoc """
  Kubernetes client entrypoint: loads the in-cluster service-account
  kubeconfig that every resource module operates against.

  In-cluster SA config everywhere, dev included (ADR-0020 — Tilt runs the
  app inside k3d), so this is a plain module: the SA step stores a
  `tokenFile` *path* in the kubeconfig and kubereq re-reads it on use —
  projected-token rotation (~1h) is handled by the library, and there is
  nothing worth caching (v1's GenServer existed for its file/base64
  kubeconfig loaders, which died with native dev).

  Tests run without a cluster: `kubeconfig/0` returns an error and resource
  modules are exercised through their pure manifest builders.
  """

  alias FluxVale.Clients.K8s.Error

  @sa_dir "/var/run/secrets/kubernetes.io/serviceaccount"

  @doc """
  Returns `true` when all in-cluster service-account files are present
  (token + ca.crt + namespace — the SA step requires all three).
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Enum.all?(["token", "ca.crt", "namespace"], &File.exists?(Path.join(@sa_dir, &1)))
  end

  @doc """
  Loads the in-cluster kubeconfig for use with the resource modules.

  Returns `{:ok, Kubereq.Kubeconfig.t()}` or `{:error, %Error{}}` when not
  running in a pod / the API server is unreachable via the mounted config.
  """
  @spec kubeconfig() :: {:ok, Kubereq.Kubeconfig.t()} | {:error, Error.t()}
  # dialyzer: kubereq's load/1 typespec disagrees with its accepted pipeline
  # steps (same mismatch v1 suppressed).
  @dialyzer {:nowarn_function, kubeconfig: 0}
  def kubeconfig do
    kubeconfig = Kubereq.Kubeconfig.load([Kubereq.Kubeconfig.ServiceAccount])

    # kubereq halts the pipeline even on success — validity is judged by the
    # loaded data, not the halted flag (v1 finding, kept).
    if is_nil(kubeconfig.current_context) or kubeconfig.clusters == [] do
      {:error,
       Error.connection_error("No in-cluster kubeconfig (service-account files missing?)")}
    else
      {:ok, kubeconfig}
    end
  rescue
    # coveralls-ignore-start - in-cluster bootstrap failure (no SA files /
    # malformed): only fires inside the cluster; local dev loads from file
    e ->
      {:error,
       Error.connection_error("Exception loading in-cluster kubeconfig: #{Exception.message(e)}")}
  end

  # coveralls-ignore-stop
end
