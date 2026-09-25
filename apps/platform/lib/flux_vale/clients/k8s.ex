defmodule FluxVale.Clients.K8s do
  @moduledoc """
  Kubernetes client entrypoint: loads the kubeconfig every resource module
  operates against.

  In-cluster SA config everywhere, dev included (ADR-0020 — Tilt runs the
  app inside k3d), so this is a plain module: the SA step stores a
  `tokenFile` *path* in the kubeconfig and kubereq re-reads it on use —
  projected-token rotation (~1h) is handled by the library, and there is
  nothing worth caching (v1's GenServer existed for its file/base64
  kubeconfig loaders, which died with native dev).

  The kubeconfigs are built via `Kubereq.Kubeconfig.new!/set_current_context`
  (transcribing kubereq's own step modules' output shapes) rather than
  `Kubereq.Kubeconfig.load/1` or direct step calls: load's typespec rejects
  the list pipelines its own body wraps, and the steps implement
  `Pluggable` with their own struct where the behaviour callback wants the
  (nonexistent-as-a-type) `Pluggable.Token.t()` — either route makes
  dialyzer infer the loader can never return `{:ok, _}`, which then
  poisons every kubeconfig consumer's contract.

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
  running in a pod / the API server env is absent.
  """
  @spec kubeconfig() :: {:ok, Kubereq.Kubeconfig.t()} | {:error, Error.t()}
  def kubeconfig do
    host = System.get_env("KUBERNETES_SERVICE_HOST")
    port = System.get_env("KUBERNETES_SERVICE_PORT_HTTPS")
    files = Enum.map(["token", "ca.crt", "namespace"], &Path.join(@sa_dir, &1))

    if is_nil(host) or is_nil(port) or not Enum.all?(files, &File.exists?/1) do
      {:error,
       Error.connection_error("No in-cluster kubeconfig (service-account files missing?)")}
    else
      {:ok, service_account_kubeconfig(host, port, files)}
    end
  end

  # Same output shape as Kubereq.Kubeconfig.ServiceAccount: a "default"
  # cluster/user/context triple, the CA by path, the token by path (kubereq
  # re-reads it per request — projected-token rotation).
  # coveralls-ignore-start - only runs inside the cluster pod (SA files +
  # apiserver env); native tests never have both, integration rides the
  # file-path kubeconfig instead.
  defp service_account_kubeconfig(host, port, [token_file, ca_file, namespace_file]) do
    cluster = %{
      "name" => "default",
      "cluster" => %{
        "certificate-authority" => ca_file,
        "server" => "https://#{host}:#{port}"
      }
    }

    user = %{"name" => "default", "user" => %{"tokenFile" => token_file}}

    context = %{
      "name" => "default",
      "context" => %{
        "cluster" => "default",
        "user" => "default",
        "namespace" => File.read!(namespace_file)
      }
    }

    kubeconfig = Kubereq.Kubeconfig.new!(clusters: [cluster], users: [user], contexts: [context])
    Kubereq.Kubeconfig.set_current_context(kubeconfig, "default")
  end

  # coveralls-ignore-stop

  @doc """
  Loads the kubeconfig a Cluster row points at (#73).

  `nil` → the in-cluster service account (the local sentinel, ADR-0006
  Am. 2). A string is a kubeconfig **file path** — the first `kubeconfig_ref`
  format, fixed by #73's host-run local-cluster integration (tests on the
  host can't read the pod's SA files). Remote formats (secret refs, managed
  APIs) arrive with ADR-0016's trigger.
  """
  @spec kubeconfig(nil | String.t()) :: {:ok, Kubereq.Kubeconfig.t()} | {:error, Error.t()}
  def kubeconfig(nil), do: kubeconfig()

  def kubeconfig(path) when is_binary(path) do
    case read_kubeconfig_file(path) do
      {:ok, kubeconfig} -> {:ok, kubeconfig}
      {:error, %Error{}} = error -> error
    end
  rescue
    # coveralls-ignore-start - a missing/unreadable/malformed kubeconfig
    # file raises inside File.read!/yaml parsing; only reachable from
    # operator-typed paths (the Cluster update surface is admin-gated).
    e ->
      {:error,
       Error.connection_error("Exception loading kubeconfig #{path}: #{Exception.message(e)}")}
  end

  # coveralls-ignore-stop

  # Same output shape as Kubereq.Kubeconfig.File: clusters/users/contexts
  # from the YAML, current context from the file's own current-context
  # field (v1's extra CurrentContext step doesn't exist in kubereq 0.4.5 —
  # it only ever ran when File failed, a halt-ordered accident).
  defp read_kubeconfig_file(path) do
    if File.exists?(path) do
      config = YamlElixir.read_from_file!(path)
      current = config["current-context"]

      if is_binary(current) do
        loaded =
          Kubereq.Kubeconfig.new!(
            clusters: config["clusters"] || [],
            users: config["users"] || [],
            contexts: config["contexts"] || []
          )

        {:ok, Kubereq.Kubeconfig.set_current_context(loaded, current)}
      else
        {:error, Error.connection_error("Invalid kubeconfig file (no current-context): #{path}")}
      end
    else
      {:error, Error.connection_error("Kubeconfig file not found: #{path}")}
    end
  end
end
