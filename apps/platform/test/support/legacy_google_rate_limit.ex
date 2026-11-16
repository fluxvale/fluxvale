# FROZEN ORACLE — a copy of FluxValeWeb.Plugs.GoogleRateLimit at a4df6059
# (2026-11-15). Delete at lane close (#510). Do not "improve" it; it is the
# before. The executable body is verbatim; docs/comments were trimmed. Only
# the module name, table name, app-env key, and GenServer name changed.
defmodule FluxVale.TestSupport.LegacyGoogleRateLimit do
  @moduledoc """
  The pre-consolidation `GoogleRateLimit`, frozen for the #510 conformance
  harness. It exists only so the same request sequence can run through the
  old and new implementations; the frozen copy is deleted at lane close.
  """

  use GenServer

  @table __MODULE__.Windows
  @default_window_seconds 60
  @default_max_requests 10
  @default_max_rows 100_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec allow?(Plug.Conn.t()) :: boolean()
  def allow?(conn) do
    window = window_start(System.system_time(:second), window_seconds())
    limit = max_requests()
    cap = max_rows()
    bump(client_ip(conn), window, limit, cap)
  end

  @spec client_ip(Plug.Conn.t()) :: String.t()
  def client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "cf-connecting-ip") do
      [value | _rest] ->
        case String.trim(value) do
          "" -> forwarded_or_remote(conn)
          trimmed -> trimmed
        end

      [] ->
        forwarded_or_remote(conn)
    end
  end

  @spec window_start(integer(), pos_integer()) :: integer()
  def window_start(epoch, window_seconds), do: div(epoch, window_seconds) * window_seconds

  @spec sweep_expired() :: :ok
  def sweep_expired do
    window = window_seconds()
    cutoff = window_start(System.system_time(:second), window) - 2 * window
    spec = [{{{:"$1", :"$2"}, :_}, [{:<, :"$2", cutoff}], [true]}]
    :ets.select_delete(@table, spec)
    :ok
  end

  # coveralls-ignore-start - the frozen copy's fail-open arm; the live
  # module's replacement covers its own arm in the engine suites.
  defp bump(ip, window, limit, cap) do
    maybe_sweep_full_table(cap)

    count = :ets.update_counter(@table, {ip, window}, {2, 1}, {{ip, window}, 0})
    count <= limit
  rescue
    ArgumentError -> true
  end

  # coveralls-ignore-stop

  defp maybe_sweep_full_table(cap) do
    if :ets.info(@table, :size) > cap do
      sweep_expired()
    end
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
    Process.send_after(self(), :sweep, window_seconds() * 1_000)
    {:noreply, table}
  end

  defp forwarded_for(conn) do
    entries =
      conn
      |> Plug.Conn.get_req_header("x-forwarded-for")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    List.last(entries)
  end

  defp forwarded_or_remote(conn) do
    case forwarded_for(conn) do
      nil -> remote_ip_string(conn)
      rightmost -> rightmost
    end
  end

  defp remote_ip_string(conn) do
    address = :inet.ntoa(conn.remote_ip)
    to_string(address)
  end

  defp window_seconds, do: config!(:window_seconds, @default_window_seconds)

  defp max_requests, do: config!(:max_requests, @default_max_requests)

  defp max_rows, do: config!(:max_rows, @default_max_rows)

  defp config!(key, default) do
    case Application.get_env(:flux_vale, __MODULE__, [])[key] do
      nil ->
        default

      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} #{key} must be a positive integer, got: #{inspect(other)}"
    end
  end
end
