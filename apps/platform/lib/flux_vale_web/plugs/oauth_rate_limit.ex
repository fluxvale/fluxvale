defmodule FluxValeWeb.Plugs.OAuthRateLimit do
  @moduledoc """
  The per-IP fixed windows on the unauthenticated OAuth endpoints
  (#766): registration, the authorization page (GET + consent POST),
  the token endpoint, and revocation.

  The key is the REAL client address — `GoogleRateLimit.client_ip/1`'s
  trusted-proxy chain (Cloudflare's `CF-Connecting-IP`, then the
  rightmost `X-Forwarded-For`, then `remote_ip`). Behind the deployed
  edge `conn.remote_ip` is a proxy pod, so keying on it would put every
  client in one bucket.

  The store is the GoogleRateLimit shape: a supervised ETS table with
  caller-side `:ets.update_counter` on `{bucket, ip, window}` keys,
  floor-bucketed windows, increment-first accounting, and a fail-open
  arm if the owner is mid-restart. A throttle must never 500 the
  sign-in door.

  ## Configuration

  Runtime-readable application env on this module (test.exs widens the
  windows like GoogleRateLimit's):

      config :flux_vale, FluxValeWeb.Plugs.OAuthRateLimit,
        max_rows: 100_000,
        buckets: %{
          register: [window_seconds: 600, max_requests: 5],
          authorize: [window_seconds: 60, max_requests: 60],
          token: [window_seconds: 60, max_requests: 60],
          revoke: [window_seconds: 60, max_requests: 60]
        }
  """

  use GenServer

  alias FluxValeWeb.Plugs.GoogleRateLimit

  @table __MODULE__.Windows
  @sweep_key {:sweep, :last}
  @default_max_rows 100_000

  @default_buckets %{
    register: [window_seconds: 600, max_requests: 5],
    authorize: [window_seconds: 60, max_requests: 60],
    token: [window_seconds: 60, max_requests: 60],
    revoke: [window_seconds: 60, max_requests: 60]
  }

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Counts this request against `{bucket, client_ip, window}`. Returns
  `:ok` or `{:error, retry_after_seconds}`.
  """
  @spec allow?(Plug.Conn.t(), atom()) :: :ok | {:error, pos_integer()}
  def allow?(conn, bucket) do
    config = bucket_config!(bucket)
    now = System.system_time(:second)
    window = window_start(now, config[:window_seconds])
    key = {bucket, GoogleRateLimit.client_ip(conn), window}
    count = bump(key, max_rows())

    if count <= config[:max_requests] do
      :ok
    else
      {:error, retry_after(now, window, config[:window_seconds])}
    end
  end

  @doc """
  The floor-bucketed window containing `epoch` — ApiRateLimit's
  arithmetic verbatim. Public for its test.
  """
  @spec window_start(integer(), pos_integer()) :: integer()
  def window_start(epoch, window_seconds), do: div(epoch, window_seconds) * window_seconds

  @doc """
  Deletes rows from windows that can no longer be written. Public for
  its test; the owner also schedules it every window.
  """
  @spec sweep_expired() :: :ok
  def sweep_expired do
    cutoff = System.system_time(:second) - 2 * max_window_seconds()
    spec = [{{{:"$1", :"$2", :"$3"}, :_}, [{:<, :"$3", cutoff}], [true]}]
    :ets.select_delete(@table, spec)
    :ok
  end

  @impl GenServer
  def init(:ok) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    send(self(), :sweep)
    {:ok, table}
  end

  @impl GenServer
  def handle_info(:sweep, table) do
    sweep_expired()
    Process.send_after(self(), :sweep, max_window_seconds() * 1_000)
    {:noreply, table}
  end

  defp bump(key, cap) do
    maybe_sweep_full_table(cap)
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
    # coveralls-ignore-start - the table-gone / owner-dying window (the
    # supervisor's restart): not sequentially stageable; fail open, the
    # next request counts again.
  rescue
    ArgumentError ->
      1
      # coveralls-ignore-stop
  end

  defp maybe_sweep_full_table(cap) do
    if :ets.info(@table, :size) > cap do
      throttle_sweep()
    end
  end

  # At most one traversal per longest window: while recent keys keep the
  # table over the cap, replaying the sweep on every request would turn
  # each counter bump into an O(table) scan. `select_replace` claims the
  # next sweep window atomically; the timestamp row is a 2-tuple, so
  # sweep_expired/0's 3-tuple match spec leaves it alone.
  defp throttle_sweep do
    now = System.system_time(:second)
    cutoff = now - max_window_seconds()
    claim = [{{@sweep_key, :"$1"}, [{:<, :"$1", cutoff}], [{{@sweep_key, now}}]}]

    if :ets.insert_new(@table, {@sweep_key, now}) or :ets.select_replace(@table, claim) == 1 do
      sweep_expired()
    end
  end

  defp retry_after(now, window, window_seconds) do
    window_end = window + window_seconds
    max(window_end - now, 1)
  end

  defp max_rows do
    config = Application.get_env(:flux_vale, __MODULE__, [])
    positive_integer!(config, :max_rows, @default_max_rows)
  end

  defp max_window_seconds do
    @default_buckets
    |> Map.keys()
    |> Enum.map(&bucket_config!(&1)[:window_seconds])
    |> Enum.max()
  end

  defp bucket_config!(bucket) do
    config = Application.get_env(:flux_vale, __MODULE__, [])
    buckets = Keyword.get(config, :buckets, @default_buckets)
    defaults = Map.fetch!(@default_buckets, bucket)
    values = Map.get(buckets, bucket, defaults)

    %{
      window_seconds: positive_integer!(values, :window_seconds, defaults[:window_seconds]),
      max_requests: positive_integer!(values, :max_requests, defaults[:max_requests])
    }
  end

  defp positive_integer!(config, key, default) do
    case Keyword.get(config, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} #{key} must be a positive integer, got: #{inspect(other)}"
    end
  end
end
