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

  The store is `FixedWindow` (#510): this module is the source — table
  name, buckets, row cap — and the engine owns the mechanics
  (increment-first counters, floor-bucketed windows, the claim-throttled
  cap sweep, the hard row bound, fail-open). A throttle must never 500
  the sign-in door.

  ## Configuration

  Runtime-readable application env on this module (test.exs widens the
  windows like GoogleRateLimit's). Every bucket is validated on every
  request — `max_window_seconds` needs them all — so a malformed bucket
  fails at the boundary even when the request is for another bucket:

      config :flux_vale, FluxValeWeb.Plugs.OAuthRateLimit,
        max_rows: 100_000,
        buckets: %{
          register: [window_seconds: 600, max_requests: 5],
          authorize: [window_seconds: 60, max_requests: 60],
          token: [window_seconds: 60, max_requests: 60],
          revoke: [window_seconds: 60, max_requests: 60],
          device_code: [window_seconds: 600, max_requests: 5]
        }
  """

  @behaviour FluxValeWeb.Plugs.FixedWindow

  alias FluxValeWeb.Plugs.FixedWindow
  alias FluxValeWeb.Plugs.GoogleRateLimit

  @table __MODULE__.Windows
  @default_max_rows 100_000

  @default_buckets %{
    register: [window_seconds: 600, max_requests: 5],
    authorize: [window_seconds: 60, max_requests: 60],
    token: [window_seconds: 60, max_requests: 60],
    revoke: [window_seconds: 60, max_requests: 60],
    # #886: the device-authorization mint — register-strict (one
    # login at a time; a restart of a failed flow still fits).
    device_code: [window_seconds: 600, max_requests: 5]
  }

  @doc false
  @impl FluxValeWeb.Plugs.FixedWindow
  @spec table() :: atom()
  def table, do: @table

  @doc false
  @impl FluxValeWeb.Plugs.FixedWindow
  @spec bucket(atom()) :: %{window_seconds: pos_integer(), max_requests: pos_integer()}
  def bucket(requested) do
    config = Application.get_env(:flux_vale, __MODULE__, [])
    buckets = Keyword.get(config, :buckets, @default_buckets)
    defaults = Map.fetch!(@default_buckets, requested)
    values = Map.get(buckets, requested, defaults)

    %{
      window_seconds: positive_integer!(values, :window_seconds, defaults[:window_seconds]),
      max_requests: positive_integer!(values, :max_requests, defaults[:max_requests])
    }
  end

  @doc false
  @impl FluxValeWeb.Plugs.FixedWindow
  @spec max_rows() :: pos_integer()
  def max_rows do
    config = Application.get_env(:flux_vale, __MODULE__, [])
    positive_integer!(config, :max_rows, @default_max_rows)
  end

  @doc false
  @impl FluxValeWeb.Plugs.FixedWindow
  @spec max_window_seconds() :: pos_integer()
  def max_window_seconds do
    @default_buckets
    |> Map.keys()
    |> Enum.map(&bucket(&1)[:window_seconds])
    |> Enum.max()
  end

  @doc """
  Counts this request against `{bucket, client_ip, window}`. Returns
  `:ok` or `{:error, retry_after_seconds}`.
  """
  @spec allow?(Plug.Conn.t(), atom()) :: :ok | {:error, pos_integer()}
  def allow?(conn, bucket) do
    FixedWindow.allow?(__MODULE__, bucket, GoogleRateLimit.client_ip(conn))
  end

  @doc """
  The floor-bucketed window containing `epoch` — ApiRateLimit's
  arithmetic verbatim. Public for its test.
  """
  @spec window_start(integer(), pos_integer()) :: integer()
  def window_start(epoch, window_seconds), do: FixedWindow.window_start(epoch, window_seconds)

  @doc """
  Deletes rows from windows that can no longer be written. Public for
  its test; the engine's owner also schedules it every longest window.
  """
  @spec sweep_expired() :: :ok
  def sweep_expired, do: FixedWindow.sweep_expired(__MODULE__)

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
