defmodule FluxValeWeb.Plugs.ApiRateLimitConfigTest do
  @moduledoc false

  # #360 slice 3: the plug's env overrides and their failure posture —
  # async: false because Application env is VM-global (the
  # runtime_config_test posture); an async module mutating the limit
  # would 429 a neighbor's PAT calls.

  use FluxValeWeb.ConnCase, async: false

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxValeWeb.Plugs.ApiRateLimit

  setup do
    user = User.create!("rate-limit-cfg@fluxvale.com", %{}, authorize?: false)

    {:ok, %{token: token}} =
      Identity.mint_pat(nil, %{user_id: user.id, name: "cfg test", scopes: []}, authorize?: false)

    %{token: token}
  end

  defp me_request(token) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> get("/api/v1/me")
  end

  # The env is global state — capture and restore (house rule), and
  # each test states the exact posture it needs.
  defp with_env(env, test) do
    original = Application.get_env(:flux_vale, ApiRateLimit)

    if env do
      Application.put_env(:flux_vale, ApiRateLimit, env)
    else
      Application.delete_env(:flux_vale, ApiRateLimit)
    end

    on_exit(fn -> Application.put_env(:flux_vale, ApiRateLimit, original) end)
    test.()
  end

  describe "the generous defaults" do
    test "govern when no env is set", %{token: token} do
      # 60s / 300 — the numbers production actually runs on (nothing
      # in prod/dev sets this key); pin them here, not just the test
      # overrides.
      with_env(nil, fn ->
        # 300 requests cannot trip ANY window: a window holds at most
        # the requests that landed in it (a mid-hammer boundary flip
        # only resets the count — never trips sooner).
        for _n <- 1..300, do: assert(json_response(me_request(token), 200)["data"])

        # The climb to the cap is < 2s of requests inside a 60s
        # window — a refusal must arrive before the next flip.
        refused =
          Enum.find_value(1..400, fn _n ->
            conn = me_request(token)
            if conn.status == 429, do: conn
          end)

        assert refused, "no refusal within 700 default-window requests"

        # the window side of the defaults: retry-after bounded by 60s
        [retry_after] = get_resp_header(refused, "retry-after")
        {seconds, ""} = Integer.parse(retry_after)
        assert seconds >= 1 and seconds <= 60
      end)
    end
  end

  describe "overrides" do
    test "retry-after floors at 1 — the last second of a window still owes a full second", %{
      token: token
    } do
      # A 1s window: whatever fraction of the second remains, the
      # truncated diff is 0 and the floor must answer 1.
      with_env([window_seconds: 1, max_requests: 1], fn ->
        assert json_response(me_request(token), 200)["data"]

        # A ms-later request may straddle into a fresh second (and
        # refill it) — keep asking until a refusal shows; any refusal
        # in a 1s window is within its last second, so the floor is
        # the deterministic assert.
        refused =
          Enum.find_value(1..6, fn _n ->
            conn = me_request(token)
            if conn.status == 429, do: conn
          end)

        assert refused, "no refusal within a handful of 1s-window requests"

        assert %{"errors" => [%{"status" => "429"}]} = Jason.decode!(refused.resp_body)
        assert get_resp_header(refused, "retry-after") == ["1"]
      end)
    end

    test "a malformed limit fails loudly at the config boundary, not mid-flight", %{token: token} do
      # The silent-failure shapes the plug refuses to ship: a string
      # max (term ordering would quietly disable the check) and a
      # zero window (an ArithmeticError on every PAT call).
      with_env([window_seconds: 60, max_requests: "300"], fn ->
        assert_raise ArgumentError, ~r/max_requests must be a positive integer/, fn ->
          me_request(token)
        end
      end)

      with_env([window_seconds: 0, max_requests: 300], fn ->
        assert_raise ArgumentError, ~r/window_seconds must be a positive integer/, fn ->
          me_request(token)
        end
      end)
    end
  end
end
