defmodule FluxVale.Infrastructure.Operations.StorageExpansion do
  @moduledoc """
  The storage-expansion capability seam (#493): whether THIS cluster's
  default StorageClass can grow a PVC (`allowVolumeExpansion`), probed
  live and cached.

  #493's up-only storage policy gates on this answer — it is the
  layer's capability, not a platform promise: local-path answers false
  today, and when the storage lane ships an expandable class (TopoLVM),
  the probe picks it up inside the TTL — no flag, no app change.

  Not a user-facing operation — same-domain callers (the resize guard)
  call it directly, InstanceK8s-style.

  The PROBE runs in the CALLER's process (the ETS cache is written
  from there too): Mimic stubs are process-local, and the client-stub
  tests depend on the seam never laundering the call through another
  process. The cache process only owns the table.
  """

  use GenServer

  alias FluxVale.Clients.K8s.Resources.StorageClass
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  # Long enough to absorb a burst of resizes without re-probing, short
  # enough that a newly-expandable cluster is honored without operator
  # action — revisit only if a third consumer needs different freshness.
  @cache_ttl_ms 5 * 60 * 1000

  @table __MODULE__.Cache

  @doc """
  Whether the instance's cluster can expand a PVC. Probe errors are
  returned honestly — the caller must never bill a capability it
  couldn't read; a probe that merely failed says "try again", a real
  no is the product boundary (the guard renders the two distinctly).
  Errors are not cached: a flaky API server re-probes on the next ask.
  """
  @spec capable?(%{cluster_id: Ash.UUID.t()}) :: {:ok, boolean()} | {:error, term()}
  def capable?(%{cluster_id: cluster_id}) do
    cached_or_probe(cluster_id)
  rescue
    # Narrowed TOCTOU: the whereis guard can pass and the owner die
    # before lookup/store touches the table — the same restart window,
    # answered as the same tuple instead of raising ArgumentError.
    # coveralls-ignore-start - the owner-dies-mid-call window is a
    # scheduler race no sequential test can stage (a deleted table
    # already fails the whereis guard); the arm keeps the seam from
    # raising a 500.
    ArgumentError ->
      {:error, :cache_unavailable}
      # coveralls-ignore-stop
  end

  defp cached_or_probe(cluster_id) do
    if :ets.whereis(@table) == :undefined do
      # Owner crashed — the supervisor's restart window. A raw lookup
      # would raise ArgumentError out of the seam; the caller owns
      # probe errors, so answer the tuple instead.
      {:error, :cache_unavailable}
    else
      outcome = lookup(cluster_id)
      probe_on_miss(cluster_id, outcome)
    end
  end

  defp probe_on_miss(_cluster_id, {:ok, allowed}), do: {:ok, allowed}

  defp probe_on_miss(cluster_id, :miss) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(%{cluster_id: cluster_id}),
         {:ok, allowed} <- StorageClass.default_allows_expansion?(kubeconfig) do
      store(cluster_id, allowed)
      {:ok, allowed}
    end
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  # The owner process's only job: hold the ETS table (a dying owner
  # drops the cache and the next probe re-fills it — no state to
  # recover).
  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  defp lookup(cluster_id) do
    case :ets.lookup(@table, cluster_id) do
      [{^cluster_id, allowed, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at,
          do: {:ok, allowed},
          else: :miss

      [] ->
        :miss
    end
  end

  defp store(cluster_id, allowed) do
    expires_at = System.monotonic_time(:millisecond) + @cache_ttl_ms
    :ets.insert(@table, {cluster_id, allowed, expires_at})
    :ok
  end
end
