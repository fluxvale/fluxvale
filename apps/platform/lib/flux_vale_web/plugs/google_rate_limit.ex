defmodule FluxValeWeb.Plugs.GoogleRateLimit do
  @moduledoc """
  The per-IP fixed window on the Google sign-in hops (#642, plan §3.2
  D-abuse): both `/auth/google` and `/auth/google/callback` count,
  bounding the outbound calls an anonymous visitor can force — one
  discovery GET per authorize hop, discovery + token exchange + JWKS
  on a successful callback, one discovery GET per forged callback.

  Not a pipeline plug: the controller calls `allow?/1` at the top of
  both actions, and the refusal is a browser-shaped redirect with
  flash (the copy lives in `AuthFlow`) — never a bare 429. Otherwise
  the ApiRateLimit posture: increment first, then check, so the
  refused request still counts.

  ## The key, and how honest it is (plan §3.2)

  Behind the deployed edge (Cloudflare → Traefik → pod,
  docs/architecture.md) `conn.remote_ip` is a proxy pod address, so
  `client_ip/1` extracts: `CF-Connecting-IP` when present, else the
  rightmost `X-Forwarded-For` entry, else `remote_ip` (a direct `mix
  phx.server`).

  The trust model, stated plainly: `CF-Connecting-IP` is trusted only
  because prod ingress is Cloudflare-only and the pod is otherwise
  unreachable — where the app answers without Cloudflare in front
  (the local k3d + Traefik stack, a bare load balancer), that header
  is client-settable and the key is attacker-rotatable: a spoofer
  mints fresh buckets at request rate and the window degrades to a
  plain request-rate bound. The rightmost-XFF fallback has the same
  shape — it is the one untrusted-hop-remaining proxy's append, which
  only helps while exactly that proxy stands in front. Revisit
  trigger (plan §3.2): the proxy chain changes again.

  ## The store

  A named ETS table owned by a supervised GenServer (the
  StorageExpansion/Edge.Activity pattern — controllers die with the
  request; the table must not). Counter writes ride caller-side
  `:ets.update_counter` on a `{ip, window}` key (atomic,
  floor-bucketed like ApiRateLimit, no read-first). The owner's jobs:
  hold the table, sweep expired windows. Because a spoofed header
  mints a fresh row per distinct value, row creation is bounded by
  request rate, not by the throttle — `max_rows` is the backstop:
  past it, the caller sweeps expired rows inline before inserting
  (rows from lapsed windows only, so a live key is never reaped; a
  current-window flood may overshoot by one window's worth before the
  rollover sweeps it — accepted, a row costs tens of bytes).

  `allow?/1` fails OPEN when the table is gone or the owner is mid
  restart (the `whereis` pass and the write can race the owner's
  death — ArgumentError is rescued): a throttle must not 500 the
  sign-in door. Exact per-IP accounting holds while the platform runs
  a single replica; revisit trigger: platform replicas scale past one
  — then the window is per-pod and the limit must move to shared
  storage.

  ## Configuration

  Application env on this module, runtime-readable (test.exs widens
  the window like ApiRateLimit's):

      config :flux_vale, FluxValeWeb.Plugs.GoogleRateLimit,
        window_seconds: 60,
        max_requests: 10,
        max_rows: 100_000
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

  @doc """
  Counts this request against the caller's IP window and answers
  whether it may proceed. Config is read OUTSIDE the fail-open arm —
  a malformed limit must raise at the boundary, not silently pass.
  """
  @spec allow?(Plug.Conn.t()) :: boolean()
  def allow?(conn) do
    window = window_start(System.system_time(:second), window_seconds())
    limit = max_requests()
    cap = max_rows()
    bump(client_ip(conn), window, limit, cap)
  end

  @doc """
  The per-IP throttle key (plan §3.2), normalized to a binary so
  every source lands in one keyspace. Pure: headers and `remote_ip`
  in, string out. The CF header is normalized BEFORE the emptiness
  check (the CaptureIpCountry posture): whitespace-only is absent,
  not the `""` bucket.
  """
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

  @doc """
  The floor-bucketed window containing `epoch` — ApiRateLimit's
  arithmetic verbatim: `div(epoch, window) * window`. Public pure
  function for its test (the roll test drives it instead of sleeping
  out a window boundary).
  """
  @spec window_start(integer(), pos_integer()) :: integer()
  def window_start(epoch, window_seconds), do: div(epoch, window_seconds) * window_seconds

  @doc """
  Deletes rows from windows that can no longer be written (the floor
  bucketing has moved past them). Public for its test — the table is
  public, so the test stages stale rows directly; the owner schedules
  this every window and the cap path calls it inline.
  """
  @spec sweep_expired() :: :ok
  def sweep_expired do
    window = window_seconds()
    cutoff = window_start(System.system_time(:second), window) - 2 * window
    spec = [{{{:"$1", :"$2"}, :_}, [{:<, :"$2", cutoff}], [true]}]
    :ets.select_delete(@table, spec)
    :ok
  end

  # coveralls-ignore-start - the table-gone / owner-dying window (the
  # supervisor's restart): not sequentially stageable, the owner is
  # re-spawned before a test can call through. Fail open — a throttle
  # must not 500 the sign-in door; the next request counts again.
  defp bump(ip, window, limit, cap) do
    maybe_sweep_full_table(cap)

    count = :ets.update_counter(@table, {ip, window}, {2, 1}, {{ip, window}, 0})
    count <= limit
  rescue
    ArgumentError -> true
  end

  # coveralls-ignore-stop

  # Past the row cap, reap the expired before inserting (the spoofed
  # -key backstop — see the moduledoc's store section).
  defp maybe_sweep_full_table(cap) do
    if :ets.info(@table, :size) > cap do
      sweep_expired()
    end
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
