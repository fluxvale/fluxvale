# FROZEN ORACLE — a copy of FluxValeWeb.Plugs.OAuthRateLimit at a4df6059
# (2026-11-15). Delete at lane close (#510). Do not "improve" it; it is the
# before. The executable body is verbatim; docs/comments were trimmed. Only
# the module name, table name, app-env key, and GenServer name changed.
defmodule FluxVale.TestSupport.LegacyOAuthRateLimit do
  @moduledoc """
  The pre-consolidation `OAuthRateLimit`, frozen for the #510 conformance
  harness. It carries the original broken `select_replace` claim body (the
  tuple claim key as a bare literal in the replacement) so S2 can prove the
  fix changes behavior; the frozen copy is deleted at lane close.
  """

  use GenServer

  alias FluxVale.TestSupport.LegacyGoogleRateLimit

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

  @spec allow?(Plug.Conn.t(), atom()) :: :ok | {:error, pos_integer()}
  def allow?(conn, bucket) do
    config = bucket_config!(bucket)
    now = System.system_time(:second)
    window = window_start(now, config[:window_seconds])
    key = {bucket, LegacyGoogleRateLimit.client_ip(conn), window}
    count = bump(key, max_rows())

    if count <= config[:max_requests] do
      :ok
    else
      {:error, retry_after(now, window, config[:window_seconds])}
    end
  end

  @spec window_start(integer(), pos_integer()) :: integer()
  def window_start(epoch, window_seconds), do: div(epoch, window_seconds) * window_seconds

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
  rescue
    ArgumentError ->
      1
  end

  defp maybe_sweep_full_table(cap) do
    if :ets.info(@table, :size) > cap do
      throttle_sweep()
    end
  end

  # The original body embeds the tuple claim key as a bare literal in the
  # match-spec replacement; ETS requires a literal replacement through
  # {:const, Row} and rejects this with "not a valid match specification".
  # bump/2's rescue turns that ArgumentError into an uncounted allow as
  # soon as any claim row exists.
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
