defmodule FluxValeWeb.Plugs.ApiRateLimitTest do
  @moduledoc false

  # #360 slice 3: the per-token fixed window — the mounted hammer
  # through the real /api/v1 pipeline, the 429 contract (byte-shape +
  # Retry-After), rollover by backdated window rows (never by
  # sleeping), and the session pass-through. test.exs pins
  # max_requests 3 / window_seconds 86_400 — every request in a test
  # run floors into one window, so the hammer needs no clock games.

  use FluxValeWeb.ConnCase, async: true

  import Ecto.Query

  alias AshAuthentication.Jwt
  alias FluxVale.Api.RequestWindow
  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Repo
  alias FluxValeWeb.Plugs.ApiRateLimit

  setup do
    user = User.create!("rate-limit@fluxvale.com", %{}, authorize?: false)

    {:ok, %{token: token, pat: pat}} =
      Identity.mint_pat(nil, %{user_id: user.id, name: "rate test", scopes: []},
        authorize?: false
      )

    %{user: user, token: token, pat: pat}
  end

  # The mounted route through the full :api_auth pipeline — the same
  # path a real client rides.
  defp me_request(token) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> get("/api/v1/me")
  end

  describe "mounted in :api_auth — the hammer" do
    test "max_requests allowed, then 429 with Retry-After", %{token: token} do
      for _n <- 1..3, do: assert(json_response(me_request(token), 200)["data"])

      refused = me_request(token)

      assert %{"errors" => [error]} = json_response(refused, 429)
      assert error["status"] == "429"
      assert error["title"] == "Too Many Requests"
      assert error["detail"] == "this token has exceeded the API rate limit"

      # AuthorizeApiScopes' rendering posture exactly: bare media
      # type, charset-free (byte-identical to every other /api/v1
      # error).
      assert ["application/vnd.api+json"] = get_resp_header(refused, "content-type")

      # Integer seconds until the window resets — plausible bounds
      # (≥1; ≤ the window width), not wall-clock exacts.
      assert [retry_after] = get_resp_header(refused, "retry-after")
      {seconds, ""} = Integer.parse(retry_after)
      assert seconds >= 1 and seconds <= 86_400

      assert refused.halted
    end

    test "tokens hammer alone — exhausting one never gates its neighbor", %{
      user: user,
      token: token
    } do
      {:ok, %{token: neighbor}} =
        Identity.mint_pat(nil, %{user_id: user.id, name: "neighbor", scopes: []},
          authorize?: false
        )

      for _n <- 1..3, do: assert(json_response(me_request(token), 200)["data"])

      assert %{"errors" => [%{"status" => "429"}]} = json_response(me_request(token), 429)

      for _n <- 1..3, do: assert(json_response(me_request(neighbor), 200)["data"])
    end

    test "refused requests still count — the meter sees every call", %{token: token, pat: pat} do
      for _n <- 1..3, do: json_response(me_request(token), 200)
      json_response(me_request(token), 429)
      json_response(me_request(token), 429)

      # Five calls through the pipeline = five in the window row —
      # the refused pair counted too (a hammer earns no free passes).
      assert window_count(pat.id) == 5
    end
  end

  describe "window rollover" do
    test "a stale window no longer gates — the request flows in a fresh one", %{
      token: token,
      pat: pat
    } do
      # Seed-only state: the bump only writes the current window, so
      # an exhausted PAST window is exactly the state the passage of
      # time (or the janitor's retention horizon not yet reached)
      # leaves behind.
      Ash.Seed.seed!(RequestWindow, %{
        token_id: pat.id,
        window_started_at: DateTime.add(DateTime.utc_now(), -2, :day),
        count: 500_000
      })

      assert json_response(me_request(token), 200)["data"]
    end
  end

  describe "who the limit applies to" do
    test "session calls neither consume nor trip the token's window", %{user: user, token: token} do
      {:ok, session_jwt, _claims} = Jwt.token_for_user(user)

      # Five session reads — over the limit — all pass, and none of
      # them touch the PAT's counter (the three later PAT calls would
      # tip over at the second if the session had shared the window).
      for _n <- 1..5 do
        session_conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Test.init_test_session(%{"user_token" => session_jwt})
          |> get("/api/v1/me")

        assert json_response(session_conn, 200)["data"]
      end

      for _n <- 1..3, do: assert(json_response(me_request(token), 200)["data"])
    end

    test "a conn with no PAT passes untouched (unauthenticated arm)" do
      conn =
        "GET"
        |> Plug.Test.conn("/api/v1/me")
        |> ApiRateLimit.call([])

      refute conn.halted
    end

    test "a session-authenticated conn passes untouched", %{user: user} do
      conn =
        "GET"
        |> Plug.Test.conn("/api/v1/me")
        |> Plug.Conn.assign(:current_user, user)
        |> ApiRateLimit.call([])

      refute conn.halted
    end
  end

  describe "configuration" do
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

    test "the generous defaults govern when no env is set", %{token: token} do
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
  end

  # The token's current-window row count — the plug's own bucketing
  # (86_400s floor, the test config), read straight off the table.
  defp window_count(token_id) do
    epoch = DateTime.to_unix(DateTime.utc_now())
    window = DateTime.from_unix!(div(epoch, 86_400) * 86_400)

    query =
      from(w in "request_windows",
        select: w.count,
        where:
          w.token_id == type(^token_id, Ecto.UUID) and
            w.window_started_at == type(^window, :utc_datetime)
      )

    Repo.one(query) || 0
  end
end
