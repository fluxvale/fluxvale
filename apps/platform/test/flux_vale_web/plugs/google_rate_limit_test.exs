defmodule FluxValeWeb.Plugs.GoogleRateLimitTest do
  @moduledoc false

  # Plan §3.2's key-extraction rule (the forge cases) and the window
  # semantics against the app-supervised owner's table. async: false —
  # the config cases mutate Application env (the ApiRateLimit
  # config-test posture), and allow?/1 reads it live.

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

    test "an empty CF header is absent — the next rule in the chain applies" do
      c = conn([{"cf-connecting-ip", ""}, {"x-forwarded-for", "10.0.0.3"}])

      assert GoogleRateLimit.client_ip(c) == "10.0.0.3"
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

    test "malformed config fails at the boundary, not mid-request" do
      for bad <- [[max_requests: "3"], [window_seconds: 0]] do
        with_config(bad, fn ->
          assert_raise ArgumentError, ~r/must be a positive integer/, fn ->
            GoogleRateLimit.allow?(conn())
          end
        end)
      end
    end
  end

  describe "sweep_expired/0" do
    test "deletes only rows from windows that can no longer be written" do
      ip = "10.254.#{unique_octet()}.#{unique_octet()}"
      window = floor_bucket(System.system_time(:second))

      :ets.insert(@table, {{ip, 0}, 99})
      :ets.insert(@table, {{ip, window}, 1})

      :ok = GoogleRateLimit.sweep_expired()

      refute :ets.member(@table, {ip, 0})
      assert :ets.member(@table, {ip, window})
    end
  end

  # The current window bucket, on the suite's configured window — the
  # module's floor-bucketing is ApiRateLimit's arithmetic verbatim.
  defp floor_bucket(epoch) do
    window = Application.fetch_env!(:flux_vale, GoogleRateLimit)[:window_seconds]
    div(epoch, window) * window
  end

  defp unique_octet, do: rem(System.unique_integer([:positive]), 250)
end
