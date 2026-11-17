defmodule FluxValeWeb.Plugs.FixedWindow do
  @moduledoc """
  The shared fixed-window store behind the per-IP throttles (#510):
  a supervised ETS table owned by one GenServer per source, with
  caller-side `:ets.update_counter` on `{bucket, ip, window}` keys.

  A source module (the behaviour below) owns the surface's shape: its
  table name, its buckets' windows and limits, its row cap, and its
  longest window. The engine owns everything mechanical — floor-bucketed
  windows, increment-first accounting, the claim-throttled cap sweep,
  and the fail-open arm.

  ## Semantics

  - **Increment first**: the counter bumps before the limit check, so a
    refused request still counts — a hammering client never earns
    uncounted requests.
  - **Floor-bucketed windows**: a request at epoch second `s` belongs to
    `div(s, window) * window`; no read-first write, `Retry-After` is the
    distance to the next boundary.
  - **The cap sweep is claim-throttled.** Past `max_rows`, the caller
    tries to claim the next sweep window atomically (`insert_new`, or
    `select_replace` on a STALE stamp) and only then scans. While recent
    keys keep the table over the cap, replaying the sweep per request
    would turn each bump into an O(table) scan; one traversal per
    longest window bounds the work. The replacement row must go through
    `{:const, Row}` — a bare literal in a match-spec body is rejected
    (#510 S2). The owner also sweeps on its own timer every longest
    window.
  - **Lapsed rows only.** The sweep deletes rows from windows strictly
    older than `window_start(now, max_window) - 2 * max_window` — the
    floor-aligned cutoff never reaches a window that can still be
    written, so a live counter is never reset.
  - **The row cap is a hard bound.** Past `max_rows`, after the
    claim-gated sweep, a request whose key has no row is admitted
    UNCOUNTED and inserts nothing; a key that already has a row still
    increments and can refuse. Overshoot is one concurrent burst's
    worth of inserts plus the claim row, and those burst rows are
    current-window rows: they hold until they lapse and the sweep
    retires them — worst case ~3× the longest window after the insert
    (window remainder + 2× under the floor cutoff), plus up to one
    window of sweep jitter. Memory never grows with the spoofed-key
    rate beyond that. Accepted trade, in the open:
    under saturation new identities bypass the throttle — the same
    identities a spoofing attacker mints for free — while repeat
    identities stay throttled; the alternatives are unbounded memory or
    denying the door. The stale-claim sweep reclaims lapsed rows every
    longest window and inserts resume the moment the table is under
    the cap.
  - **Fail open.** A gone-or-restarting table rescues into count 1
    (allowed): a throttle must not 500 the sign-in door; the next
    request counts again. Config is read and validated OUTSIDE that
    arm — a malformed limit raises at the boundary, not mid-request.

  Not a Plug. `GoogleRateLimit` and `OAuthRateLimit` are the sources;
  their controllers keep their own refusal shapes.
  """

  use GenServer

  @sweep_key {:sweep, :last}

  @doc false
  @callback table() :: atom()

  @doc false
  @callback bucket(atom()) :: %{
              window_seconds: pos_integer(),
              max_requests: pos_integer()
            }

  @doc false
  @callback max_rows() :: pos_integer()

  @doc false
  @callback max_window_seconds() :: pos_integer()

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    source = Keyword.fetch!(opts, :source)

    %{
      id: Keyword.get(opts, :id, source),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    source = Keyword.fetch!(opts, :source)
    name = Keyword.get(opts, :name, source)
    GenServer.start_link(__MODULE__, source, name: name)
  end

  @doc """
  Counts this request against `{bucket, ip, window}` in `source`'s
  table. Returns `:ok` or `{:error, retry_after_seconds}`.
  """
  @spec allow?(module(), atom(), String.t()) :: :ok | {:error, pos_integer()}
  def allow?(source, bucket, ip) do
    config = source.bucket(bucket)
    cap = source.max_rows()
    max_window = source.max_window_seconds()

    now = System.system_time(:second)
    window = window_start(now, config[:window_seconds])
    key = {bucket, ip, window}
    count = bump(source.table(), key, cap, max_window)

    if count <= config[:max_requests] do
      :ok
    else
      {:error, retry_after(now, window, config[:window_seconds])}
    end
  end

  @doc """
  The floor-bucketed window containing `epoch` — ApiRateLimit's
  arithmetic verbatim. Public for the sources' tests.
  """
  @spec window_start(integer(), pos_integer()) :: integer()
  def window_start(epoch, window_seconds), do: div(epoch, window_seconds) * window_seconds

  @doc """
  Deletes rows from windows that can no longer be written. The owner
  schedules this every longest window; the cap path calls it under a
  claim. Public for the sources' tests.
  """
  @spec sweep_expired(module()) :: :ok
  def sweep_expired(source) do
    :ok = sweep_table(source.table(), source.max_window_seconds())
  end

  # The owner's only jobs: hold the table, sweep it per longest window.
  @impl GenServer
  def init(source) do
    table = :ets.new(source.table(), [:named_table, :set, :public, read_concurrency: true])
    send(self(), :sweep)
    {:ok, %{source: source, table: table}}
  end

  @impl GenServer
  def handle_info(:sweep, %{source: source} = state) do
    :ok = sweep_expired(source)
    Process.send_after(self(), :sweep, source.max_window_seconds() * 1_000)
    {:noreply, state}
  end

  # Increment first; the fail-open arm covers the table-gone window (the
  # supervisor's restart), staged by the conformance suite's stopped
  # owner — the next request counts again.
  #
  # The row cap is a HARD bound: past it — after the claim-gated sweep —
  # a request whose key has no row is admitted UNCOUNTED and inserts
  # nothing, so the spoofed-key RATE cannot grow memory past the cap
  # (the unbounded term is concurrency: one burst's worth of inserts
  # that passed the size check before any landed). A key that already
  # has a row still increments (and can refuse). Fail open, never 500.
  defp bump(table, key, cap, max_window) do
    maybe_sweep_full_table(table, cap, max_window)

    cond do
      :ets.info(table, :size) <= cap ->
        :ets.update_counter(table, key, {2, 1}, {key, 0})

      :ets.member(table, key) ->
        :ets.update_counter(table, key, {2, 1})

      true ->
        1
    end
  rescue
    ArgumentError -> 1
  end

  # Past the row cap, reap the expired before inserting (the spoofed-key
  # backstop) — but at most one traversal per longest window.
  defp maybe_sweep_full_table(table, cap, max_window) do
    size = :ets.info(table, :size)

    if is_integer(size) and size > cap do
      claim_sweep(table, max_window)
    end
  end

  # `select_replace` claims the next sweep window atomically: only a
  # STALE stamp matches the guard. The claim row is a 2-tuple, so
  # sweep_table's 3-tuple match spec leaves it alone.
  defp claim_sweep(table, max_window) do
    now = System.system_time(:second)
    cutoff = now - max_window
    claim = [{{@sweep_key, :"$1"}, [{:<, :"$1", cutoff}], [{:const, {@sweep_key, now}}]}]

    if :ets.insert_new(table, {@sweep_key, now}) or :ets.select_replace(table, claim) == 1 do
      :ok = sweep_table(table, max_window)
    end
  end

  defp sweep_table(table, max_window) do
    cutoff = window_start(System.system_time(:second), max_window) - 2 * max_window
    spec = [{{{:"$1", :"$2", :"$3"}, :_}, [{:<, :"$3", cutoff}], [true]}]
    :ets.select_delete(table, spec)
    :ok
  end

  defp retry_after(now, window, window_seconds) do
    window_end = window + window_seconds
    max(window_end - now, 1)
  end
end
