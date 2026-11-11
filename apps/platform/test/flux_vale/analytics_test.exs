defmodule FluxVale.AnalyticsTest do
  @moduledoc false

  # async: false — the armed arm flips the (:flux_vale, :posthog) app
  # env, VM-global state, captured and restored via on_exit (the
  # PostHogRequestContext test's posture).
  use FluxVale.DataCase, async: false

  alias FluxVale.Analytics

  setup do
    original = Application.get_env(:flux_vale, :posthog)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:flux_vale, :posthog)
        value -> Application.put_env(:flux_vale, :posthog, value)
      end
    end)

    # The SDK's own test posture (PostHog.Application builds the same
    # pair when test_mode is on): the ownership server plus the
    # supervision tree keep every captured event in memory —
    # PostHog.Test.all_captured/0 — and the sender never sees the
    # network in this mode.
    config =
      PostHog.Config.validate!(
        api_key: "phc_test_posthog_key",
        api_host: "https://eu.i.posthog.com",
        test_mode: true
      )

    start_supervised!({NimbleOwnership, name: PostHog.Ownership})
    start_supervised!({PostHog.Supervisor, config})

    :ok
  end

  describe "capture/3" do
    test "inert (the suite's shape): :ok, and the SDK is never called" do
      Application.delete_env(:flux_vale, :posthog)

      assert :ok = Analytics.capture("instance deployed", "user-1", %{instance_slug: "acme"})

      # Nothing reached the SDK — the tree is running in test_mode, so
      # a stray capture would have landed here.
      assert PostHog.Test.all_captured() == []
    end

    test "armed: the event reaches the SDK with the id from the argument and the props" do
      Application.put_env(:flux_vale, :posthog, %{:api_key => "phc_test_posthog_key"})

      assert :ok = Analytics.capture("instance deployed", "user-1", %{instance_slug: "acme"})

      assert [
               %{
                 event: "instance deployed",
                 distinct_id: "user-1",
                 properties: %{instance_slug: "acme"}
               }
             ] = PostHog.Test.all_captured()
    end

    test "armed: props can never override the distinct id — the argument wins" do
      Application.put_env(:flux_vale, :posthog, %{:api_key => "phc_test_posthog_key"})

      assert :ok = Analytics.capture("wallet topped up", "actor-1", %{distinct_id: "spoofed-1"})

      assert [%{distinct_id: "actor-1", properties: %{}}] = PostHog.Test.all_captured()
    end

    test "armed, anonymous (nil id): :ok — the SDK drops events without a distinct id" do
      Application.put_env(:flux_vale, :posthog, %{:api_key => "phc_test_posthog_key"})

      assert :ok = Analytics.capture("instance wake triggered", nil, %{app_slug: "kavita"})

      assert PostHog.Test.all_captured() == []
    end

    test "props default to empty" do
      Application.put_env(:flux_vale, :posthog, %{:api_key => "phc_test_posthog_key"})

      assert :ok = Analytics.capture("org member invited", "owner-1")

      assert [%{event: "org member invited", properties: %{}}] = PostHog.Test.all_captured()
    end
  end
end
