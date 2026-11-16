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
    # The third case is the eager one: the request is for :register, but
    # max_window_seconds validates every bucket, so a malformed :token
    # fails at the boundary too (the engine reads all config before the
    # fail-open arm — #510 S3).
    bad_configs = [
      [buckets: %{register: [window_seconds: 0, max_requests: 1]}],
      [max_rows: 0],
      [buckets: %{token: [window_seconds: 0, max_requests: 1]}]
    ]

    for bad <- bad_configs do
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

  test "the row cap claims and sweeps when no claim exists yet" do
    stale = "10.238.#{unique_octet()}.#{unique_octet()}"
    live = {10, 237, unique_octet(), unique_octet()}

    # This test owns the claim state: a leftover fresh claim from another
    # test would block the insert_new arm this test exercises.
    :ets.delete(@table, {:sweep, :last})
    :ets.insert(@table, {{:register, stale, 0}, 99})
    :ets.insert(@table, {{:register, stale <> "-2", 0}, 99})

    with_config(
      [max_rows: 1, buckets: %{register: [window_seconds: 86_400, max_requests: 5]}],
      fn ->
        live_conn = conn([], live)
        assert :ok = OAuthRateLimit.allow?(live_conn, :register)
        refute :ets.member(@table, {:register, stale, 0})
        refute :ets.member(@table, {:register, stale <> "-2", 0})

        # The insert_new arm claimed this sweep window on the way in.
        assert [{{:sweep, :last}, stamp}] = :ets.lookup(@table, sweep_key())
        assert stamp > 0
      end
    )
  end

  test "a fresh claim still refuses a saturated key and does not re-scan" do
    other = "10.235.#{unique_octet()}.#{unique_octet()}"
    target = "10.234.#{unique_octet()}.#{unique_octet()}"
    lapsed = "10.233.#{unique_octet()}.#{unique_octet()}"
    now = System.system_time(:second)
    window = OAuthRateLimit.window_start(now, 86_400)

    with_config(
      [max_rows: 1, buckets: %{register: [window_seconds: 86_400, max_requests: 2]}],
      fn ->
        # Over cap with live rows, a FRESH claim, a lapsed row the
        # throttled sweep must not reach, and a key already at its limit.
        :ets.insert(@table, {{:register, other, window}, 1})
        :ets.insert(@table, {{:register, target, window}, 2})
        :ets.insert(@table, {{:register, lapsed, 0}, 99})
        :ets.insert(@table, {{:sweep, :last}, now})

        target_conn = conn([], ip_tuple(target))
        assert {:error, retry_after} = OAuthRateLimit.allow?(target_conn, :register)
        assert retry_after >= 1

        assert :ets.lookup(@table, {:register, target, window}) == [
                 {{:register, target, window}, 3}
               ]

        # The guard only replaces a STALE stamp: this one is fresh, so
        # no sweep ran (the lapsed row survives) and the stamp stands.
        assert :ets.member(@table, {:register, lapsed, 0})
        assert :ets.lookup(@table, {:sweep, :last}) == [{{:sweep, :last}, now}]
      end
    )
  end

  test "a stale claim re-arms via select_replace and sweeps" do
    other = "10.245.#{unique_octet()}.#{unique_octet()}"
    target = "10.244.#{unique_octet()}.#{unique_octet()}"
    lapsed = "10.243.#{unique_octet()}.#{unique_octet()}"
    now = System.system_time(:second)
    window = OAuthRateLimit.window_start(now, 86_400)

    with_config(
      [max_rows: 1, buckets: %{register: [window_seconds: 86_400, max_requests: 2]}],
      fn ->
        :ets.insert(@table, {{:register, other, window}, 1})
        :ets.insert(@table, {{:register, target, window}, 2})
        :ets.insert(@table, {{:register, lapsed, 0}, 99})
        # Stale: older than the longest window, so the claim is up for
        # grabs again.
        :ets.insert(@table, {{:sweep, :last}, 0})

        target_conn = conn([], ip_tuple(target))
        assert {:error, _retry_after} = OAuthRateLimit.allow?(target_conn, :register)

        assert :ets.lookup(@table, {:register, target, window}) == [
                 {{:register, target, window}, 3}
               ]

        # The claim refreshed and the sweep it unlocked ran.
        assert [{{:sweep, :last}, stamp}] = :ets.lookup(@table, {:sweep, :last})
        assert stamp >= now
        refute :ets.member(@table, {:register, lapsed, 0})
      end
    )
  end

  defp ip_tuple(ip) do
    ip
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end

  defp unique_octet, do: rem(System.unique_integer([:positive]), 250)
end
