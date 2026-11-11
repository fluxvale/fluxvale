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
        |> put_req_header("x-posthog-distinct-id", "spoofed-distinct-id")
        |> put_req_header("x-posthog-session-id", "spoofed-session-id")
        |> PostHogRequestContext.call(opts)

      context = PostHog.get_context()

      # The client-supplied tracing headers are stripped from the SDK's
      # view — attribution is not caller-controlled until the client
      # slice wires the real ones.
      refute Map.has_key?(context, :distinct_id)
      refute Map.has_key?(context, :"$session_id")
      assert context[:"$pathname"] == "/pricing"
      assert context[:"$request_method"] == "GET"
      assert context[:"$current_url"] == "http://www.example.com/pricing"

      # The REAL conn continues downstream untouched: headers, query and
      # path survive (MaybeResolveUser.return_to reads the query).
      assert conn.query_string == "plan=storage"
      assert get_req_header(conn, "x-posthog-distinct-id") == ["spoofed-distinct-id"]
      assert conn.request_path == "/pricing"
    end

    test "the query string never reaches the context — auth-boundary tokens stay out" do
      # #408: the invitation accept route rides ?token=… and the raw
      # token IS the invitee-side credential (CodeRabbit finding) — the
      # shipped context is path-only.
      Application.put_env(:flux_vale, :posthog, %{:api_key => "phc_test_posthog_key"})

      base = build_conn(:get, "/invitations/accept?token=supersecret-invite-token")
      opts = PostHogRequestContext.init([])

      conn = PostHogRequestContext.call(base, opts)

      context = PostHog.get_context()

      # The side effect fired: the request's context landed…
      assert context[:"$pathname"] == "/invitations/accept"
      assert context[:"$request_method"] == "GET"
      # …with no token in it…
      assert context[:"$current_url"] == "http://www.example.com/invitations/accept"
      refute context[:"$current_url"] =~ "supersecret"
      # …and the RETURNED conn (what MaybeResolveUser/UserAuth read
      # downstream) keeps the query the stripped view dropped.
      assert conn.query_string == "token=supersecret-invite-token"
      assert conn.request_path == "/invitations/accept"
    end
  end
end
