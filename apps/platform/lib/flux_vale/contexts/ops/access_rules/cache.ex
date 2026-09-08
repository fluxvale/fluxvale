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

  TTL 0 (test config) makes the cache inert: reads go straight to the
  table, so every test is instantly consistent and nothing reads through
  a snapshot another test stale-dated.
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
  A no-op while the cache is disabled.
  """
  @spec refresh() :: :ok
  def refresh do
    if enabled?() do
      snapshot = read_all()
      :ok = store(snapshot)
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

  # {nil, _} — never read; {_snapshot, false} — aged past the TTL
  defp maybe_refresh({nil, _freshness}) do
    snapshot = read_all()
    :ok = store(snapshot)
    snapshot
  end

  defp maybe_refresh({snapshot, true}), do: snapshot

  @impl GenServer
  @spec init(:ok) :: {:ok, %{snapshot: snapshot() | nil, refreshed_at: DateTime.t() | nil}}
  def init(:ok), do: {:ok, %{snapshot: nil, refreshed_at: nil}}

  @impl GenServer
  @spec handle_call(atom(), GenServer.from(), map()) :: {:reply, term(), map()}
  def handle_call(:current, _from, state) do
    {:reply, {state.snapshot, fresh?(state)}, state}
  end

  def handle_call({:store, snapshot}, _from, _state),
    do: {:reply, :ok, %{snapshot: snapshot, refreshed_at: DateTime.utc_now()}}

  defp fresh?(%{refreshed_at: nil}), do: false

  defp fresh?(%{refreshed_at: refreshed_at}) do
    refreshed_at
    |> DateTime.diff(DateTime.utc_now(), :second)
    |> then(&(abs(&1) < ttl_seconds()))
  end

  defp store(snapshot), do: GenServer.call(__MODULE__, {:store, snapshot})

  defp ttl_seconds,
    do: Application.get_env(:flux_vale, :access_rules_cache_ttl_seconds, 60)
end
