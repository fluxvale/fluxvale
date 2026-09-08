defmodule FluxVale.Ops.AccessRules.Cache do
  @moduledoc """
  Per-node snapshot of the `access_rules` table (settled on #26).

  The cache process only **holds** state — every DB read happens in the
  calling process, which pushes the result in. That keeps the holder
  trivially restartable and out of the SQL sandbox's way in test.

  Lazy TTL: `snapshot/0` returns the held rows until they age past
  `config :flux_vale, :access_rules_cache_ttl_seconds` (60 default), then
  re-reads. Mutations force-refresh through `refresh/0` (the BustCache
  change) — the mutating node is instant, and the TTL is the **cross-node**
  revocation bound (ADR-0023 Am. 1's "sever ≤ TTL" exit criterion).

  Racing readers can't regress the cache: every store carries the
  generation it read against, and a store from an older generation is
  discarded — a delayed read may start before a mutation and land after
  it, but can never overwrite the post-mutation snapshot (CodeRabbit,
  #48). TTL 0 (test config) makes the cache inert: reads go straight to
  the table, so every test is instantly consistent and nothing reads
  through a snapshot another test stale-dated.
  """

  use GenServer

  alias FluxVale.Ops.AccessRule

  @typedoc "A snapshot: every AccessRule row, in read order."
  @type snapshot :: [AccessRule.t()]

  @doc """
  The current snapshot — held while fresh, re-read (caller-side) when stale.
  """
  @spec snapshot() :: snapshot()
  def snapshot do
    if enabled?() do
      __MODULE__
      |> GenServer.call(:current)
      |> maybe_refresh()
    else
      read_all()
    end
  end

  @doc """
  Force an immediate re-read (after every AccessRule mutation — BustCache).
  Stores unconditionally — the mutating node's read is authoritative by
  construction (it runs inside the mutation's transaction). A no-op while
  the cache is disabled.
  """
  @spec refresh() :: :ok
  def refresh do
    if enabled?() do
      snapshot = read_all()
      :ok = store(snapshot, :force)
      :ok
    else
      :ok
    end
  end

  @doc """
  Reads the table uncached — the stale path's re-read and the refresher
  itself. `authorize?: false`: a machine read of global config, the same
  posture as the FeatureFlags evaluator lookup.
  """
  @spec read_all() :: snapshot()
  def read_all, do: Ash.read!(AccessRule, authorize?: false)

  @doc false
  @spec enabled?() :: boolean()
  def enabled?, do: ttl_seconds() > 0

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  # {snapshot, freshness, gen} — the generation rides along so a store
  # from a read that raced a newer store can be discarded server-side
  defp maybe_refresh({snapshot, true, _gen}), do: snapshot

  defp maybe_refresh({_stale, _fresh, gen}) do
    snapshot = read_all()
    :ok = store(snapshot, gen)
    snapshot
  end

  @impl GenServer
  @spec init(:ok) ::
          {:ok, %{snapshot: snapshot() | nil, refreshed_at: DateTime.t() | nil, gen: integer()}}
  def init(:ok), do: {:ok, %{snapshot: nil, refreshed_at: nil, gen: 0}}

  @impl GenServer
  @spec handle_call(atom(), GenServer.from(), map()) :: {:reply, term(), map()}
  def handle_call(:current, _from, state),
    do: {:reply, {state.snapshot, fresh?(state), state.gen}, state}

  # The bust path: the mutating node's read is authoritative — always wins
  def handle_call({:store, snapshot, :force}, _from, _state),
    do: {:reply, :ok, recorded(snapshot)}

  # A stale-generation store is discarded: its read raced a newer store (a
  # bust or a fresher read) — keeping the older snapshot would restore
  # revoked access for up to a TTL
  def handle_call({:store, _older, stale_gen}, _from, %{gen: gen} = state)
      when stale_gen < gen,
      do: {:reply, :ok, state}

  def handle_call({:store, snapshot, _current_gen}, _from, _state),
    do: {:reply, :ok, recorded(snapshot)}

  # Positive-monotonic per-VM — strictly increasing, so a stale read's
  # generation is always strictly less than any store that landed after
  # its read (and greater than the never-read init gen of 0)
  defp recorded(snapshot) do
    gen = System.unique_integer([:positive, :monotonic])
    %{snapshot: snapshot, refreshed_at: DateTime.utc_now(), gen: gen}
  end

  defp fresh?(%{refreshed_at: nil}), do: false

  defp fresh?(%{refreshed_at: refreshed_at}) do
    refreshed_at
    |> DateTime.diff(DateTime.utc_now(), :second)
    |> then(&(abs(&1) < ttl_seconds()))
  end

  defp store(snapshot, gen), do: GenServer.call(__MODULE__, {:store, snapshot, gen})

  defp ttl_seconds,
    do: Application.get_env(:flux_vale, :access_rules_cache_ttl_seconds, 60)
end
