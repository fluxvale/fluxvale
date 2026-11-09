defmodule FluxValeWeb.Plugs.GoogleRateLimit do
  @moduledoc """
  The per-IP fixed window on the Google sign-in hops (#642, plan §3.2
  D-abuse): both `/auth/google` and `/auth/google/callback` count,
  bounding the outbound calls an anonymous visitor can force — one
  discovery GET per authorize hop, discovery + token exchange + JWKS
  on a successful callback, one discovery GET per forged callback.

  Not a pipeline plug: the controller calls `allow?/1` at the top of
  both actions, and the refusal is a browser-shaped redirect with
  flash (the copy lives in the controller) — never a bare 429.
  Otherwise the ApiRateLimit posture: increment first, then check, so
  the refused request still counts.

  ## The key (plan §3.2)

  Behind the deployed edge (Cloudflare → Traefik → pod,
  docs/architecture.md) `conn.remote_ip` is a proxy pod address, so
  `client_ip/1` extracts: `CF-Connecting-IP` when present (Cloudflare
  sets and overwrites it on the proxied path; a client cannot forge
  it through), else the rightmost `X-Forwarded-For` entry (the
  address the one untrusted-hop-remaining proxy appended — the local
  k3d + Traefik stack), else `remote_ip` (a direct `mix phx.server`).
  Revisit trigger: the proxy chain changes again.

  ## The store

  A named ETS table owned by a supervised GenServer (the
  StorageExpansion/Edge.Activity pattern — controllers die with the
  request; the table must not). Counter writes ride caller-side
  `:ets.update_counter` on a `{ip, window}` key (atomic, floor-bucketed
  like ApiRateLimit, no read-first); the owner's only jobs are holding
  the table and sweeping expired windows so it stays bounded. Exact
  per-IP accounting holds while the platform runs a single replica;
  revisit trigger: platform replicas scale past one — then the window
  is per-pod and the limit must move to shared storage.

  ## Configuration

  Application env on this module, runtime-readable (test.exs widens
  the window like ApiRateLimit's):

      config :flux_vale, FluxValeWeb.Plugs.GoogleRateLimit,
        window_seconds: 60,
        max_requests: 10
  """

  use GenServer

  @table __MODULE__.Windows
  @default_window_seconds 60
  @default_max_requests 10

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Counts this request against the caller's IP window and answers
  whether it may proceed. Fail-open when the table is gone: the
  owner's restart window must not 500 the sign-in door.
  """
  @spec allow?(Plug.Conn.t()) :: boolean()
  def allow?(conn) do
    if :ets.whereis(@table) == :undefined do
      # coveralls-ignore-start - the supervisor's restart window races
      # any sequential staging (a killed owner is re-spawned before a
      # test can call through) — the same class as the concurrency
      # windows the sandbox cannot open.
      true
      # coveralls-ignore-stop
    else
      ip = client_ip(conn)
      window = window_start(window_seconds())

      count = :ets.update_counter(@table, {ip, window}, {2, 1}, {{ip, window}, 0})
      count <= max_requests()
    end
  end

  @doc """
  The per-IP throttle key (plan §3.2), normalized to a binary so
  every source lands in one keyspace. Pure: headers and `remote_ip`
  in, string out.
  """
  @spec client_ip(Plug.Conn.t()) :: String.t()
  def client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "cf-connecting-ip") do
      [ip | _rest] when is_binary(ip) and ip != "" ->
        String.trim(ip)

      _no_cf_header ->
        case forwarded_for(conn) do
          nil -> remote_ip_string(conn)
          rightmost -> rightmost
        end
    end
  end

  @doc """
  Deletes rows from windows that can no longer be written (the floor
  bucketing has moved past them). Public for its test — the table is
  public, so the test stages stale rows directly; the owner schedules
  this every window.
  """
  @spec sweep_expired() :: :ok
  def sweep_expired do
    window = window_seconds()
    cutoff = window_start(window) - 2 * window
    spec = [{{{:"$1", :"$2"}, :_}, [{:<, :"$2", cutoff}], [true]}]
    :ets.select_delete(@table, spec)
    :ok
  end

  # The owner's only jobs: hold the table, sweep it per window.
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

  # The rightmost non-empty entry across every X-Forwarded-For value
  # (proxies append): the one untrusted-hop-remaining proxy's append —
  # forged leftmost entries ride before it and lose.
  defp forwarded_for(conn) do
    entries =
      conn
      |> Plug.Conn.get_req_header("x-forwarded-for")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    List.last(entries)
  end

  defp remote_ip_string(conn) do
    address = :inet.ntoa(conn.remote_ip)
    to_string(address)
  end

  # ApiRateLimit's floor bucketing verbatim: a request at epoch second
  # s belongs to the window starting at div(s, window) * window —
  # aligned to the clock, and the write needs no read first.
  defp window_start(window_seconds) do
    epoch = DateTime.to_unix(DateTime.utc_now())
    bucket = div(epoch, window_seconds) * window_seconds
    bucket
  end

  defp window_seconds, do: config!(:window_seconds, @default_window_seconds)

  defp max_requests, do: config!(:max_requests, @default_max_requests)

  # ApiRateLimit's config! verbatim: fail at the config boundary, not
  # mid-request — a string limit would silently disable the check, a
  # zero window would ArithmeticError every hop.
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
