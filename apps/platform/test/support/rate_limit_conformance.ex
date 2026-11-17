defmodule FluxVale.TestSupport.RateLimitConformance do
  @moduledoc """
  One request sequence, the live fixed-window implementations (#510).

  The adapters wrap the live modules, so a change can run the same steps
  through both surfaces and compare the thing that must not change: the
  allow/refuse decision. `run/2` executes the steps against one adapter's
  table; `verdicts/1` strips the retry value so Google's boolean and
  OAuth's `{:error, retry}` compare as `:ok` / `:refused`.

  The pre-lane frozen oracles that proved the S1-S5 refactor
  behavior-preserving lived beside this module and were deleted at lane
  close (#510).
  """

  alias FluxValeWeb.Plugs.GoogleRateLimit
  alias FluxValeWeb.Plugs.OAuthRateLimit

  @type adapter :: %{
          allow: (Plug.Conn.t(), atom() -> term()),
          sweep: (-> term()),
          table: atom(),
          key: (atom(), String.t(), integer() -> tuple())
        }

  @spec current_google() :: adapter()
  def current_google do
    %{
      allow: fn conn, _bucket -> GoogleRateLimit.allow?(conn) end,
      sweep: fn -> GoogleRateLimit.sweep_expired() end,
      table: GoogleRateLimit.Windows,
      key: fn _bucket, ip, window -> {:google, ip, window} end
    }
  end

  @spec current_oauth() :: adapter()
  def current_oauth do
    %{
      allow: fn conn, bucket -> OAuthRateLimit.allow?(conn, bucket) end,
      sweep: fn -> OAuthRateLimit.sweep_expired() end,
      table: OAuthRateLimit.Windows,
      key: fn bucket, ip, window -> {bucket, ip, window} end
    }
  end

  @doc "A bare conn with the given headers and remote address."
  @spec conn([{String.t(), String.t()}], :inet.ip_address()) :: Plug.Conn.t()
  def conn(headers \\ [], remote_ip \\ {192, 0, 2, 9}) do
    %Plug.Conn{req_headers: headers, remote_ip: remote_ip}
  end

  @doc "A `:inet` parse of a dotted IPv4 string."
  @spec ip_tuple(String.t()) :: :inet.ip_address()
  def ip_tuple(ip) do
    ip
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end

  @doc """
  A per-run address in the 198.18/15 benchmarking range. The compression
  to two variable octets has 62,500 values and `System.unique_integer`
  is monotonic within a run, so a collision needs a 62,500-draw span —
  the suite draws a few hundred.
  """
  @spec unique_ip() :: String.t()
  def unique_ip do
    n = System.unique_integer([:positive])
    "198.18.#{rem(n, 250)}.#{rem(div(n, 250), 250)}"
  end

  # Step constructors — the sequence reads as the request story.
  def allow(conn, bucket), do: {:allow, conn, bucket}
  def stage(bucket, ip, window, count), do: {:stage, bucket, ip, window, count}
  def sweep, do: :sweep

  @doc """
  Runs `steps` against `adapter`. Allow steps yield `{:allow, decision}`;
  state steps yield `{:staged, :ok}` or `{:sweep, :ok}`.
  """
  @spec run(adapter(), list()) :: list()
  def run(adapter, steps) do
    Enum.map(steps, fn
      {:allow, conn, bucket} ->
        {:allow, decision(adapter.allow.(conn, bucket))}

      {:stage, bucket, ip, window, count} ->
        :ets.insert(adapter.table, {adapter.key.(bucket, ip, window), count})
        {:staged, :ok}

      :sweep ->
        {:sweep, adapter.sweep.()}
    end)
  end

  @doc "The allow/refuse decisions from a `run/2`, retry value stripped."
  @spec verdicts(list()) :: [:ok | :refused]
  def verdicts(results) do
    for {:allow, decision} <- results, do: strip(decision)
  end

  @doc "Normalizes an implementation result to `:ok` / `:refused` / `{:refused, retry}`."
  @spec decision(term()) :: :ok | :refused | {:refused, pos_integer()}
  def decision(true), do: :ok
  def decision(false), do: :refused
  def decision(:ok), do: :ok
  def decision({:error, retry}) when is_integer(retry) and retry > 0, do: {:refused, retry}

  defp strip({:refused, _retry}), do: :refused
  defp strip(:ok), do: :ok
  defp strip(:refused), do: :refused
end
