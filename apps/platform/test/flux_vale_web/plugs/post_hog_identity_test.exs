defmodule FluxValeWeb.Plugs.PostHogIdentityTest do
  @moduledoc false

  # async: false — the armed arm flips the (:flux_vale, :posthog) app
  # env: VM-global state, captured and restored via on_exit.
  use FluxValeWeb.ConnCase, async: false

  alias FluxValeWeb.Plugs.PostHogIdentity

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
    test "no-op while unarmed (the suite's shape), even with a resolved user" do
      Application.delete_env(:flux_vale, :posthog)

      conn =
        build_conn()
        |> assign(:current_user, %{id: "usr_123"})
        |> PostHogIdentity.call(PostHogIdentity.init([]))

      assert PostHog.get_context() == %{}
      assert conn.assigns[:current_user] == %{id: "usr_123"}
    end

    test "no-op while armed but anonymous" do
      arm_posthog()

      conn = PostHogIdentity.call(build_conn(), PostHogIdentity.init([]))

      assert PostHog.get_context() == %{}
      assert conn.request_path == "/"
    end

    test "the resolved user becomes the distinct_id (SDK context read-back)" do
      arm_posthog()

      conn =
        build_conn()
        |> assign(:current_user, %{id: "usr_123"})
        |> PostHogIdentity.call(PostHogIdentity.init([]))

      assert PostHog.get_context() == %{distinct_id: "usr_123"}
      assert conn.assigns[:current_user] == %{id: "usr_123"}
    end
  end

  # Presence is all this plug reads; the supervision tree stays down, so
  # set_context (process-scoped logger metadata) never touches the wire.
  defp arm_posthog do
    Application.put_env(:flux_vale, :posthog, %{:api_key => "phc_test_posthog_key"})
  end
end
