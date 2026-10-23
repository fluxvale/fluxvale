defmodule FluxVale.Edge.Activity do
  @moduledoc """
  The beacon's debounce (#203, ADR-0036): Traefik consults the touch
  endpoint on EVERY forwarded request, but the idle clock only needs
  minute-resolution — at most one `last_used_at` write per instance per
  window, however hot the traffic. The window markers live in this
  GenServer's ETS table; the clock itself is the DB row (a restart
  loses only the open windows — the next touch re-seeds, and the sweep
  reads the row, never the table).

  A failed write leaves the window open (the marker updates only after
  the write commits), so the next touch retries instead of silently
  stretching the idle clock — a lost marker means an instance stays
  awake longer, never wrongly sleeps.

  `mark/1` never raises on the caller: the beacon's contract is that
  nothing here can 500 the forwarded request (a wedged GenServer or a
  slow DB answers `{:error, _}`, and the handler 204s anyway). The
  same table debounces the wake endpoint's serving-route restores —
  one apply attempt per window per instance, so a public GET loop
  can't turn into unthrottled K8s writes.
  """

  use GenServer

  alias FluxVale.Infrastructure.Instance

  @table :flux_vale_edge_activity
  # 30s of marker resolution against a 1h threshold — 0.8% slop, and
  # the write rate is bounded at 2/min/instance however hot the edge.
  @window_seconds 30
  # The mark path waits at most this long for the GenServer — the
  # forwarded request's latency budget is small, and the fallback is
  # benign (no mark; the next touch retries).
  @mark_timeout 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Marks an instance as used, debounced. Synchronous so unit tests need
  no sleeps; the beacon handler treats the response as advisory — a
  failed mark never fails the forwarded request. `{:ok, :marked |
  :debounced}` or `{:error, reason}` (the write failed or the server
  is wedged; the window stays open for the next touch).
  """
  @spec mark(Ash.UUID.t()) :: {:ok, :marked | :debounced} | {:error, term()}
  def mark(instance_id) do
    GenServer.call(__MODULE__, {:mark, instance_id}, @mark_timeout)
  catch
    # exit, not rescue: GenServer timeouts and DOWNs are exits, and
    # the beacon contract is "answer 204 regardless".
    :exit, _reason ->
      {:error, :overloaded}
  end

  @doc """
  Claims this window's serving-route restore for the instance:
  `:proceed` for the first caller in the window, `:throttled` after.
  """
  @spec claim_restore(Ash.UUID.t()) :: :proceed | :throttled
  def claim_restore(instance_id) do
    GenServer.call(__MODULE__, {:claim, {:restore, instance_id}}, @mark_timeout)
  catch
    :exit, _reason ->
      # A wedged server can't throttle — treat as proceed (idempotent
      # apply; the cost is one redundant SSA write).
      :proceed
  end

  @impl GenServer
  def init(:ok) do
    table = :ets.new(@table, [:named_table, :set, read_concurrency: true])
    {:ok, table}
  end

  @impl GenServer
  def handle_call({:mark, instance_id}, _from, table) do
    now = System.monotonic_time(:second)
    last_flush = :ets.lookup_element(table, instance_id, 2, nil)

    if fresh?(now, last_flush) do
      {:reply, {:ok, :debounced}, table}
    else
      reply = mark_instance(table, instance_id, now)
      {:reply, reply, table}
    end
  end

  def handle_call({:claim, key}, _from, table) do
    now = System.monotonic_time(:second)
    last_claim = :ets.lookup_element(table, key, 2, nil)

    if fresh?(now, last_claim) do
      {:reply, :throttled, table}
    else
      :ets.insert(table, {key, now})
      {:reply, :proceed, table}
    end
  end

  defp mark_instance(table, instance_id, now) do
    case fetch_and_touch(instance_id) do
      {:ok, _instance} ->
        :ets.insert(table, {instance_id, now})
        {:ok, :marked}

      {:error, reason} ->
        # A gone row (stale middleware after teardown) takes its
        # window marker with it — the table must not outgrow the
        # fleet. Other errors keep the window open (see moduledoc).
        if not_found?(reason), do: :ets.delete(table, instance_id)
        {:error, reason}
    end
  end

  # The code interface's update entrypoint takes the record; the beacon
  # only carries the id its middleware was minted with.
  defp fetch_and_touch(instance_id) do
    with {:ok, instance} <- Instance.get_by_id(instance_id, authorize?: false) do
      Instance.touch(instance, authorize?: false)
    end
  end

  defp not_found?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  # coveralls-ignore-start - defensive: fetch_and_touch's error tuples
  # are always Ash Invalid shapes today; the catch-all is the guard if
  # that ever widens (a touch failure keeps the window open either way).
  defp not_found?(_other), do: false
  # coveralls-ignore-stop

  # No marker (first touch, or post-restart) or a lapsed window.
  defp fresh?(now, last_flush), do: window_open?(now, last_flush)

  @doc """
  The window arithmetic, on the monotonic seconds the table stores:
  true while `last` is no older than the window. Public for its test —
  the table is owner-writable only (serialized claims), so a lapsed
  marker can't be staged from outside.
  """
  @spec window_open?(integer(), integer() | nil) :: boolean()
  def window_open?(_now, nil), do: false

  def window_open?(now, last) when is_integer(last) do
    now - last < @window_seconds
  end
end
