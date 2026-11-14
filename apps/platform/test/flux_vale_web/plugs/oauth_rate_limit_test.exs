defmodule FluxValeWeb.Plugs.OAuthRateLimitTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias FluxValeWeb.Plugs.OAuthRateLimit

  @table FluxValeWeb.Plugs.OAuthRateLimit.Windows

  defp conn(headers \\ [], remote_ip \\ {192, 0, 2, 9}) do
    %Plug.Conn{req_headers: headers, remote_ip: remote_ip}
  end

  defp with_config(overrides, test) do
    original = Application.get_env(:flux_vale, OAuthRateLimit)
    Application.put_env(:flux_vale, OAuthRateLimit, overrides)
    on_exit(fn -> restore(original) end)
    test.()
  end

  defp restore(nil), do: Application.delete_env(:flux_vale, OAuthRateLimit)
  defp restore(value), do: Application.put_env(:flux_vale, OAuthRateLimit, value)

  defp sweep_key do
    @table
    |> :ets.tab2list()
    |> Enum.find_value(fn
      {{:sweep, :last} = key, _stamp} -> key
      _other -> nil
    end)
  end

  test "window_start/2 floors to the window boundary" do
    assert OAuthRateLimit.window_start(179, 60) == 120
    assert OAuthRateLimit.window_start(120, 60) == 120
    assert OAuthRateLimit.window_start(119, 60) == 60
  end

  test "the bucket counts per real client IP and refuses over the limit" do
    ip = {10, 240, unique_octet(), unique_octet()}
    from_ip = fn -> conn([], ip) end

    with_config(
      [
        buckets: %{
          register: [window_seconds: 86_400, max_requests: 2],
          authorize: [window_seconds: 86_400, max_requests: 2],
          token: [window_seconds: 86_400, max_requests: 2],
          revoke: [window_seconds: 86_400, max_requests: 2]
        }
      ],
      fn ->
        assert :ok = OAuthRateLimit.allow?(from_ip.(), :register)
        assert :ok = OAuthRateLimit.allow?(from_ip.(), :register)
        assert {:error, retry_after} = OAuthRateLimit.allow?(from_ip.(), :register)
        assert retry_after >= 1

        other = {10, 241, unique_octet(), unique_octet()}
        other_conn = conn([], other)
        assert :ok = OAuthRateLimit.allow?(other_conn, :register)
      end
    )
  end

  test "CF-Connecting-IP keys the bucket, not the proxy's remote_ip" do
    with_config(
      [
        buckets: %{
          register: [window_seconds: 86_400, max_requests: 1],
          authorize: [window_seconds: 86_400, max_requests: 1],
          token: [window_seconds: 86_400, max_requests: 1],
          revoke: [window_seconds: 86_400, max_requests: 1]
        }
      ],
      fn ->
        behind_edge = conn([{"cf-connecting-ip", "203.0.113.#{unique_octet()}"}], {10, 0, 0, 1})
        assert :ok = OAuthRateLimit.allow?(behind_edge, :token)

        cf_headers = Plug.Conn.get_req_header(behind_edge, "cf-connecting-ip")
        cf_header = hd(cf_headers)

        same_client_other_proxy =
          conn([{"cf-connecting-ip", cf_header}], {10, 0, 0, 2})

        assert {:error, _retry_after} = OAuthRateLimit.allow?(same_client_other_proxy, :token)
      end
    )
  end

  test "malformed config fails at the boundary" do
    for bad <- [[buckets: %{register: [window_seconds: 0, max_requests: 1]}], [max_rows: 0]] do
      with_config(bad, fn ->
        assert_raise ArgumentError, ~r/must be a positive integer/, fn ->
          OAuthRateLimit.allow?(conn(), :register)
        end
      end)
    end
  end

  test "sweep_expired/0 deletes only lapsed windows" do
    ip = "10.239.#{unique_octet()}.#{unique_octet()}"
    now = System.system_time(:second)
    window = OAuthRateLimit.window_start(now, 86_400)

    :ets.insert(@table, {{:register, ip, 0}, 99})
    :ets.insert(@table, {{:register, ip, window}, 1})

    :ok = OAuthRateLimit.sweep_expired()

    refute :ets.member(@table, {:register, ip, 0})
    assert :ets.member(@table, {:register, ip, window})
  end

  test "the row cap sweeps expired rows inline" do
    stale = "10.238.#{unique_octet()}.#{unique_octet()}"
    live = {10, 237, unique_octet(), unique_octet()}

    :ets.insert(@table, {{:register, stale, 0}, 99})
    :ets.insert(@table, {{:register, stale <> "-2", 0}, 99})

    with_config(
      [max_rows: 1, buckets: %{register: [window_seconds: 86_400, max_requests: 5]}],
      fn ->
        live_conn = conn([], live)
        assert :ok = OAuthRateLimit.allow?(live_conn, :register)
        refute :ets.member(@table, {:register, stale, 0})

        # The next over-cap request is inside the sweep window: it must
        # not re-scan. Age the throttle stamp to the boundary and the
        # claim replaces it once, then sweeps again.
        sweep_key = sweep_key()
        :ets.insert(@table, {sweep_key, 0})

        octet_one = unique_octet()
        octet_two = unique_octet()
        next_conn = conn([], {10, 236, octet_one, octet_two})
        assert :ok = OAuthRateLimit.allow?(next_conn, :register)
      end
    )
  end

  defp unique_octet, do: rem(System.unique_integer([:positive]), 250)
end
