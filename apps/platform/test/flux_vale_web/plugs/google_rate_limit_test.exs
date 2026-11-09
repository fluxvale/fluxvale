defmodule FluxValeWeb.Plugs.GoogleRateLimitTest do
  @moduledoc false

  # Plan §3.2's key-extraction rule (the forge cases), the window
  # semantics against the app-supervised owner's table, and the
  # spoofed-key row cap. async: false — the config cases mutate
  # Application env (the ApiRateLimit config-test posture), and
  # allow?/1 reads it live.

  use ExUnit.Case, async: false

  alias FluxValeWeb.Plugs.GoogleRateLimit

  @table FluxValeWeb.Plugs.GoogleRateLimit.Windows

  defp conn(headers \\ [], remote_ip \\ {192, 0, 2, 9}) do
    %Plug.Conn{req_headers: headers, remote_ip: remote_ip}
  end

  defp with_config(overrides, test) do
    original = Application.get_env(:flux_vale, GoogleRateLimit)
    Application.put_env(:flux_vale, GoogleRateLimit, overrides)
    on_exit(fn -> Application.put_env(:flux_vale, GoogleRateLimit, original) end)
    test.()
  end

  describe "client_ip/1 — the §3.2 extraction rule" do
    test "CF-Connecting-IP wins over XFF and remote_ip" do
      c = conn([{"cf-connecting-ip", "203.0.113.7"}, {"x-forwarded-for", "1.1.1.1, 2.2.2.2"}])

      assert GoogleRateLimit.client_ip(c) == "203.0.113.7"
    end

    test "CF is normalized BEFORE the emptiness check — whitespace is absent, not the \"\" bucket" do
      padded = conn([{"cf-connecting-ip", " 203.0.113.9 "}])
      assert GoogleRateLimit.client_ip(padded) == "203.0.113.9"

      # Whitespace-only falls through to the next rule in the chain
      # (the CaptureIpCountry posture)
      blank = conn([{"cf-connecting-ip", "   "}, {"x-forwarded-for", "10.0.0.3"}])
      assert GoogleRateLimit.client_ip(blank) == "10.0.0.3"

      empty = conn([{"cf-connecting-ip", ""}], {198, 51, 100, 3})
      assert GoogleRateLimit.client_ip(empty) == "198.51.100.3"
    end

    test "a forged XFF list keys on the RIGHTMOST entry" do
      c = conn([{"x-forwarded-for", "6.6.6.6, 7.7.7.7, 8.8.8.8"}])

      assert GoogleRateLimit.client_ip(c) == "8.8.8.8"
    end

    test "multiple XFF headers join — the last proxy's append still wins" do
      c = conn([{"x-forwarded-for", "6.6.6.6"}, {"x-forwarded-for", "9.9.9.9"}])

      assert GoogleRateLimit.client_ip(c) == "9.9.9.9"
    end

    test "entries are trimmed and empties never become the key" do
      c = conn([{"x-forwarded-for", " 10.0.0.1 ,  10.0.0.2 "}])
      assert GoogleRateLimit.client_ip(c) == "10.0.0.2"

      # An all-empty XFF is no XFF at all — remote_ip answers
      empty = conn([{"x-forwarded-for", " , "}], {198, 51, 100, 3})
      assert GoogleRateLimit.client_ip(empty) == "198.51.100.3"
    end

    test "both headers absent — remote_ip, normalized to a binary" do
      four = conn([], {198, 51, 100, 4})
      six = conn([], {0, 0, 0, 0, 0, 0, 0, 1})

      assert GoogleRateLimit.client_ip(four) == "198.51.100.4"
      assert GoogleRateLimit.client_ip(six) == "::1"
    end

    test "a forged XFF keys the forger's bucket, not the neighbour beside them" do
      spammer = conn([{"x-forwarded-for", "6.6.6.6"}], {10, 253, 1, 1})
      neighbour = conn([], {10, 253, 1, 2})

      assert GoogleRateLimit.client_ip(spammer) == "6.6.6.6"
      assert GoogleRateLimit.client_ip(neighbour) == "10.253.1.2"
    end
  end

  describe "window_start/2 — the floor bucketing" do
    test "a request at second s belongs to div(s, window) * window" do
      assert GoogleRateLimit.window_start(179, 60) == 120
      assert GoogleRateLimit.window_start(120, 60) == 120
      assert GoogleRateLimit.window_start(119, 60) == 60
      assert GoogleRateLimit.window_start(0, 60) == 0
    end
  end

  describe "allow?/1 — the fixed window" do
    test "increments first, then checks: the refused request still counts" do
      ip = {10, 250, unique_octet(), unique_octet()}
      from_ip = fn -> conn([], ip) end

      with_config([window_seconds: 86_400, max_requests: 2], fn ->
        assert GoogleRateLimit.allow?(from_ip.())
        assert GoogleRateLimit.allow?(from_ip.())
        # Over the limit — every further request refuses, and counts:
        # a hammering client never earns uncounted requests
        refute GoogleRateLimit.allow?(from_ip.())
        refute GoogleRateLimit.allow?(from_ip.())
      end)
    end

    test "distinct IPs never share a window" do
      with_config([window_seconds: 86_400, max_requests: 1], fn ->
        one = {10, 251, unique_octet(), unique_octet()}
        two = {10, 252, unique_octet(), unique_octet()}
        first = conn([], one)
        again = conn([], one)
        other = conn([], two)

        assert GoogleRateLimit.allow?(first)
        refute GoogleRateLimit.allow?(again)
        assert GoogleRateLimit.allow?(other)
      end)
    end

    test "a saturated key rolls into a fresh window (staged rows, no sleep)" do
      ip = {10, 249, unique_octet(), unique_octet()}
      address = :inet.ntoa(ip)
      key = to_string(address)
      # The suite's configured day-long window: the boundary cannot
      # pass mid-test (the ApiRateLimit suite accepts the same
      # UTC-midnight millisecond straddle).
      now = System.system_time(:second)
      window = GoogleRateLimit.window_start(now, 86_400)

      # The PAST window was saturated…
      :ets.insert(@table, {{key, window - 86_400}, 99})

      # …and the current window is fresh: the same IP is admitted
      fresh = conn([], ip)
      assert GoogleRateLimit.allow?(fresh)

      # …while a saturated CURRENT window still refuses
      :ets.insert(@table, {{key, window}, 99})
      saturated = conn([], ip)
      refute GoogleRateLimit.allow?(saturated)
    end

    test "malformed config fails at the boundary, not mid-request" do
      for bad <- [[max_requests: "3"], [window_seconds: 0], [max_rows: 0]] do
        with_config(bad, fn ->
          assert_raise ArgumentError, ~r/must be a positive integer/, fn ->
            GoogleRateLimit.allow?(conn())
          end
        end)
      end
    end
  end

  describe "the row cap (the spoofed-key backstop)" do
    test "past max_rows the caller sweeps expired rows inline before inserting" do
      stale_one = "10.248.#{unique_octet()}.#{unique_octet()}"
      stale_two = "10.246.#{unique_octet()}.#{unique_octet()}"
      live = "10.247.#{unique_octet()}.#{unique_octet()}"
      now = System.system_time(:second)
      window = GoogleRateLimit.window_start(now, 86_400)

      # Two staged stale rows: the cap is EXCEEDED (>) regardless of
      # whatever rows other tests left behind — order-independent
      :ets.insert(@table, {{stale_one, 0}, 99})
      :ets.insert(@table, {{stale_two, 0}, 99})

      with_config([window_seconds: 86_400, max_requests: 50, max_rows: 1], fn ->
        # The stale rows exceed the cap of 1: the next allow? sweeps
        # them inline (rows from lapsed windows only) and counts
        # normally — the live window's row survives
        from_live = conn([], ip_tuple(live))
        assert GoogleRateLimit.allow?(from_live)
        refute :ets.member(@table, {stale_one, 0})
        refute :ets.member(@table, {stale_two, 0})
        assert :ets.member(@table, {live, window})
      end)
    end
  end

  describe "sweep_expired/0" do
    test "deletes only rows from windows that can no longer be written" do
      ip = "10.254.#{unique_octet()}.#{unique_octet()}"
      now = System.system_time(:second)
      window = GoogleRateLimit.window_start(now, 86_400)

      :ets.insert(@table, {{ip, 0}, 99})
      :ets.insert(@table, {{ip, window}, 1})

      :ok = GoogleRateLimit.sweep_expired()

      refute :ets.member(@table, {ip, 0})
      assert :ets.member(@table, {ip, window})
    end
  end

  defp ip_tuple(ip) do
    ip
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end

  defp unique_octet, do: rem(System.unique_integer([:positive]), 250)
end
