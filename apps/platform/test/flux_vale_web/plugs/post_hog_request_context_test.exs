defmodule FluxValeWeb.Plugs.PostHogRequestContextTest do
  @moduledoc false

  # async: false — the armed arm flips the (:flux_vale, :posthog) app
  # env, which this plug (and the endpoint wrapper) reads per request:
  # VM-global state, captured and restored via on_exit.
  use FluxValeWeb.ConnCase, async: false

  alias FluxValeWeb.Plugs.PostHogRequestContext

  setup do
    original = Application.get_env(:flux_vale, :posthog)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:flux_vale, :posthog)
        value -> Application.put_env(:flux_vale, :posthog, value)
      end
    end)

    :ok
  end

  describe "call/2" do
    test "no-op while unarmed (the suite's shape): no request context is set" do
      Application.delete_env(:flux_vale, :posthog)

      conn = PostHogRequestContext.call(build_conn(), PostHogRequestContext.init([]))

      assert PostHog.get_context() == %{}
      assert conn.request_path == "/"
    end

    test "delegates to the SDK plug while armed: the request context lands" do
      # Presence is all this plug reads — the map's full shape is the
      # observability test's business. The supervision tree stays down,
      # so this stays network-free.
      Application.put_env(:flux_vale, :posthog, %{:api_key => "phc_test_posthog_key"})

      base = build_conn(:get, "/pricing?plan=storage")
      opts = PostHogRequestContext.init([])

      conn =
        base
        |> put_req_header("x-posthog-distinct-id", "frontend-distinct-id")
        |> PostHogRequestContext.call(opts)

      context = PostHog.get_context()

      assert context[:"$pathname"] == "/pricing"
      assert context[:"$request_method"] == "GET"
      assert context[:"$current_url"] == "http://www.example.com/pricing"
      assert context[:distinct_id] == "frontend-distinct-id"
      assert conn.request_path == "/pricing"
    end

    test "the query string never reaches the context — auth-boundary tokens stay out" do
      # #408: the invitation accept route rides ?token=… and the raw
      # token IS the invitee-side credential (CodeRabbit finding) — the
      # shipped context is path-only.
      Application.put_env(:flux_vale, :posthog, %{:api_key => "phc_test_posthog_key"})

      base = build_conn(:get, "/invitations/accept?token=supersecret-invite-token")
      opts = PostHogRequestContext.init([])

      _conn = PostHogRequestContext.call(base, opts)

      context = PostHog.get_context()

      assert context[:"$current_url"] == "http://www.example.com/invitations/accept"
      refute context[:"$current_url"] =~ "supersecret"
      assert context[:"$pathname"] == "/invitations/accept"
      # The caller's conn is untouched — only the SDK's view is stripped.
      assert base.query_string == "token=supersecret-invite-token"
    end
  end
end
