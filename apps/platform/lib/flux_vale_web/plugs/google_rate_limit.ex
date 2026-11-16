defmodule FluxValeWeb.Plugs.GoogleRateLimit do
  @moduledoc """
  The per-IP fixed window on the Google sign-in hops (#642, plan §3.2
  D-abuse): both `/auth/google` and `/auth/google/callback` count,
  bounding the outbound calls an anonymous visitor can force — one
  discovery GET per authorize hop, discovery + token exchange + JWKS
  on a successful callback, one discovery GET per forged callback.

  Not a pipeline plug: the controller calls `allow?/1` at the top of
  both actions, and the refusal is a browser-shaped redirect with
  flash (the copy lives in `AuthFlow`) — never a bare 429. The
  increment-first posture: a refused request still counts.

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

  The store is `FixedWindow` (#510, since S4): this module is the
  source — table name, the one `:google` bucket's window and limit,
  the row cap — and the engine owns the mechanics. The key is
  `{:google, client_ip, window}`. The row cap is a HARD bound (S5):
  past it, after the claim-gated sweep of lapsed rows, a request whose
  key has no row is admitted uncounted and inserts nothing, so a
  spoofed-header flood minting fresh keys cannot grow memory past
  `max_rows` by more than one concurrent burst's worth of inserts plus
  the claim row (burst rows are current-window rows; they hold until
  they lapse and the sweep retires them); a key that already has a row
  still counts and can refuse. Inside the claim window the sweep does
  not re-scan (S4's change: rows from lapsed windows may linger up to
  one longest window — accepted, they can no longer be written, and
  the per-request O(table) scan they used to cost was a CPU denial
  vector). A throttle must not 500 the sign-in door.

  Exact per-IP accounting holds while the platform runs a single
  replica; revisit trigger: platform replicas scale past one — then
  the window is per-pod and the limit must move to shared storage.

  ## Configuration

  Application env on this module, runtime-readable (test.exs widens
  the window like ApiRateLimit's):

      config :flux_vale, FluxValeWeb.Plugs.GoogleRateLimit,
        window_seconds: 60,
        max_requests: 10,
        max_rows: 100_000
  """

  @behaviour FluxValeWeb.Plugs.FixedWindow

  alias FluxValeWeb.Plugs.FixedWindow

  @table __MODULE__.Windows
  @bucket :google
  @default_window_seconds 60
  @default_max_requests 10
  @default_max_rows 100_000

  @doc false
  @impl FluxValeWeb.Plugs.FixedWindow
  @spec table() :: atom()
  def table, do: @table

  @doc false
  @impl FluxValeWeb.Plugs.FixedWindow
  @spec bucket(:google) :: %{window_seconds: pos_integer(), max_requests: pos_integer()}
  def bucket(@bucket), do: %{window_seconds: window_seconds(), max_requests: max_requests()}

  @doc false
  @impl FluxValeWeb.Plugs.FixedWindow
  @spec max_rows() :: pos_integer()
  def max_rows, do: config!(:max_rows, @default_max_rows)

  @doc false
  @impl FluxValeWeb.Plugs.FixedWindow
  @spec max_window_seconds() :: pos_integer()
  def max_window_seconds, do: window_seconds()

  @doc """
  Counts this request against the caller's IP window and answers
  whether it may proceed. Config is read OUTSIDE the engine's fail-open
  arm — a malformed limit must raise at the boundary, not silently pass.
  """
  @spec allow?(Plug.Conn.t()) :: boolean()
  def allow?(conn) do
    case FixedWindow.allow?(__MODULE__, @bucket, client_ip(conn)) do
      :ok -> true
      {:error, _retry_after} -> false
    end
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
  arithmetic verbatim. Public pure function for its test (the roll
  test drives it instead of sleeping out a window boundary).
  """
  @spec window_start(integer(), pos_integer()) :: integer()
  def window_start(epoch, window_seconds), do: FixedWindow.window_start(epoch, window_seconds)

  @doc """
  Deletes rows from windows that can no longer be written. Public for
  its test — the engine's owner schedules it every longest window and
  the cap path calls it under a claim.
  """
  @spec sweep_expired() :: :ok
  def sweep_expired, do: FixedWindow.sweep_expired(__MODULE__)

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
