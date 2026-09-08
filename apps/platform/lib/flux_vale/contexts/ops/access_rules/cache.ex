defmodule FluxVale.Ops.AccessRules.Cache do
  @moduledoc """
  Per-node snapshot of the `access_rules` table (settled on #26).

  The cache process only **holds** state — every DB read happens in the
  calling process, which pushes the result in. That keeps the holder
  trivially restartable and out of the SQL sandbox's way in test.

  Lazy TTL: `snapshot/0` returns the held rows until they age past
  `config :flux_vale, :access_rules_cache_ttl_seconds` (60 default), then
  re-reads. Mutations force a refresh (`refresh/0`, from BustCache) — the
  mutating node is instant, and the TTL is the **cross-node** revocation
  bound (ADR-0023 Am. 1's "sever ≤ TTL" exit criterion).

  Racing readers can't regress the cache: every store is stamped with the
  monotonic time its read **started**, and a store whose stamp is not
  newer than the held one is discarded (CodeRabbit, #48) — whichever
  store lands last, the snapshot from the newest-started read wins, so
  an older overlapping refresh cannot restore a deleted rule.

  Known residual, deliberately bounded: a mutation's own refresh reads
  inside its transaction, so two mutations overlapping within
  milliseconds can leave the cache missing the loser's change —
  self-healing within one TTL. `after_transaction` would read post-commit
  and close it, but is not honored from module changes on the bulk path
  (verified: never fires); revisit only if concurrent admin rule edits
  ever actually race (CodeRabbit, #48).

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
  The read is stamped; it only lands if it started newer than whatever is
  held — overlapping mutations can't restore a revoked rule. A no-op while
  the cache is disabled.
  """
  @spec refresh() :: :ok
  def refresh do
    if enabled?() do
      {snapshot, stamp} = stamped_read()
      :ok = store(snapshot, stamp)
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

  # {snapshot, freshness, stamp} — the stamp rides along so a store from a
  # read that started before a newer read can be discarded server-side
  defp maybe_refresh({snapshot, true, _stamp}), do: snapshot

  defp maybe_refresh({_stale, _freshness, _stamp}) do
    {snapshot, stamp} = stamped_read()
    :ok = store(snapshot, stamp)
    snapshot
  end

  # The stamp is taken BEFORE the read: a read that started before a commit
  # is "as of" before it, even if it finishes after — and the mutation's
  # own post-commit refresh always starts later and wins
  defp stamped_read do
    stamp = System.monotonic_time()
    {read_all(), stamp}
  end

  @impl GenServer
  @spec init(:ok) ::
          {:ok,
           %{
             snapshot: snapshot() | nil,
             refreshed_at: DateTime.t() | nil,
             read_stamp: integer() | nil
           }}
  def init(:ok), do: {:ok, %{snapshot: nil, refreshed_at: nil, read_stamp: nil}}

  @impl GenServer
  @spec handle_call(atom(), GenServer.from(), map()) :: {:reply, term(), map()}
  def handle_call(:current, _from, state) do
    {:reply, {state.snapshot, fresh?(state), state.read_stamp}, state}
  end

  # A store is accepted only when its read started newer than whatever is
  # held — an older overlapping refresh (racing mutations, delayed lazy
  # reads) can never overwrite a newer snapshot, so a deleted rule cannot
  # be restored for the TTL (CodeRabbit, #48). NB: the is_integer guard —
  # nil (never-held) must not compare (term order would put any stamp
  # "below" nil and discard the first store)
  def handle_call({:store, _older, stamp}, _from, %{read_stamp: held} = state)
      when is_integer(held) and stamp <= held,
      do: {:reply, :ok, state}

  def handle_call({:store, snapshot, stamp}, _from, _state),
    do: {:reply, :ok, %{snapshot: snapshot, refreshed_at: DateTime.utc_now(), read_stamp: stamp}}

  defp fresh?(%{refreshed_at: nil}), do: false

  defp fresh?(%{refreshed_at: refreshed_at}) do
    refreshed_at
    |> DateTime.diff(DateTime.utc_now(), :second)
    |> then(&(abs(&1) < ttl_seconds()))
  end

  defp store(snapshot, stamp),
    do: GenServer.call(__MODULE__, {:store, snapshot, stamp})

  defp ttl_seconds,
    do: Application.get_env(:flux_vale, :access_rules_cache_ttl_seconds, 60)
end
