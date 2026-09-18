defmodule FluxVale.Clients.K8s.Resources.Node do
  @moduledoc """
  Read operations for Kubernetes Nodes.

  Node status + aggregated allocatable capacity — the cluster-health and
  placement surfaces.

  ## Capacity units

  - CPU: `Decimal` cores (`"4"` → 4.0, `"500m"` → 0.5)
  - Memory: integer MiB (`"8Gi"` → 8192, `"1024Ki"` → 1)
  """

  alias FluxVale.Clients.K8s.Error

  require Logger

  @typedoc "Aggregated cluster capacity"
  @type capacity :: %{
          cpu: Decimal.t(),
          memory: non_neg_integer()
        }

  @doc "Lists all nodes in the cluster."
  @spec list(Kubereq.Kubeconfig.t()) :: {:ok, list(map())} | {:error, Error.t()}
  def list(kubeconfig) do
    req = create_req(kubeconfig)

    case Kubereq.list(req) do
      {:ok, %{status: 200, body: %{"items" => items}}} ->
        {:ok, items}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.from_response({:ok, %{status: status, body: body}})}

      {:error, error} ->
        {:error, Error.from_response({:error, error})}
    end
  end

  @doc """
  Gets a node by name. `{:error, %Error{reason: :not_found}}` if absent.
  """
  @spec get(Kubereq.Kubeconfig.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(kubeconfig, name) do
    req = create_req(kubeconfig)

    case Kubereq.get(req, name) do
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

  @doc """
  Aggregates allocatable CPU + memory across all nodes.

  Empty cluster → `{:ok, %{cpu: 0, memory: 0}}`.
  """
  @spec capacity(Kubereq.Kubeconfig.t()) :: {:ok, capacity()} | {:error, Error.t()}
  def capacity(kubeconfig) do
    case list(kubeconfig) do
      {:ok, nodes} ->
        total_cpu =
          nodes
          |> Enum.map(&parse_cpu(get_in(&1, ["status", "allocatable", "cpu"])))
          |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

        total_memory =
          nodes
          |> Enum.map(&parse_memory(get_in(&1, ["status", "allocatable", "memory"])))
          |> Enum.sum()

        Logger.debug("Cluster capacity: #{total_cpu} CPU cores, #{total_memory} MiB memory")

        {:ok, %{cpu: total_cpu, memory: total_memory}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Parses a Kubernetes CPU quantity to Decimal cores.

  `"4"` → 4.0, `"500m"` → 0.5, `"1500m"` → 1.5. Garbage and nil parse to 0 —
  same defensiveness as `parse_memory/1`.
  """
  @spec parse_cpu(String.t() | nil) :: Decimal.t()
  def parse_cpu(nil), do: Decimal.new(0)

  def parse_cpu(string) when is_binary(string) do
    if String.ends_with?(string, "m") do
      string
      |> String.trim_trailing("m")
      |> parse_decimal()
      |> Decimal.div(Decimal.new(1000))
    else
      parse_decimal(string)
    end
  end

  defp parse_decimal(string) do
    case Decimal.parse(string) do
      {%Decimal{} = value, _rest} -> value
      :error -> Decimal.new(0)
    end
  end

  @doc """
  Parses a Kubernetes memory quantity to integer MiB.

  `"8192Mi"` → 8192, `"8Gi"` → 8192, `"1024Ki"` → 1, `"1Ti"` → 1_048_576.
  Sub-MiB values truncate (integer division). Bare numbers are treated as
  MiB — defensive only; node allocatable is always suffixed.
  """
  @spec parse_memory(String.t() | nil) :: non_neg_integer()
  def parse_memory(nil), do: 0

  def parse_memory(string) when is_binary(string) do
    cond do
      String.ends_with?(string, "Ki") ->
        parse_suffixed(string, "Ki", &div(&1, 1024))

      String.ends_with?(string, "Mi") ->
        parse_suffixed(string, "Mi", & &1)

      String.ends_with?(string, "Gi") ->
        parse_suffixed(string, "Gi", &Kernel.*(&1, 1024))

      String.ends_with?(string, "Ti") ->
        parse_suffixed(string, "Ti", &Kernel.*(&1, 1024 * 1024))

      String.ends_with?(string, "Pi") ->
        parse_suffixed(string, "Pi", &Kernel.*(&1, 1024 * 1024 * 1024))

      String.ends_with?(string, "Ei") ->
        parse_suffixed(string, "Ei", &Kernel.*(&1, 1024 * 1024 * 1024 * 1024))

      true ->
        parse_integer(string)
    end
  end

  defp parse_suffixed(string, suffix, to_mib) do
    string
    |> String.trim_trailing(suffix)
    |> parse_integer()
    |> then(to_mib)
  end

  defp parse_integer(string) do
    case Integer.parse(string) do
      {value, _rest} -> value
      :error -> 0
    end
  end

  defp create_req(kubeconfig) do
    Kubereq.attach(Req.new(), kubeconfig: kubeconfig, api_version: "v1", kind: "Node")
  end
end
