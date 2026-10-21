defmodule FluxValeWeb.Plugs.StorybookEnabledTest do
  @moduledoc false

  # test.exs boots with :storybook_enabled true — the allow-path rides
  # that; the 404 path flips the env and restores it (tests own their
  # preconditions).

  use FluxValeWeb.ConnCase, async: true

  alias FluxValeWeb.Plugs.StorybookEnabled

  describe "call/2" do
    test "passes through when the workshop is enabled" do
      conn = StorybookEnabled.call(build_conn(), [])

      refute conn.halted
    end

    test "halts with 404 when disabled (the prod default)" do
      restore = Application.get_env(:flux_vale, :storybook_enabled)
      Application.put_env(:flux_vale, :storybook_enabled, false)
      on_exit(fn -> Application.put_env(:flux_vale, :storybook_enabled, restore) end)

      conn = StorybookEnabled.call(build_conn(), [])

      assert conn.halted
      assert conn.status == 404
      assert conn.resp_body == "Not Found"
    end
  end

  describe "the /storybook route" do
    test "renders the workshop shell when enabled" do
      conn = get(build_conn(), "/storybook")
      conn_b = get(recycle(conn), "/storybook/components/badge")

      assert html_response(conn_b, 200) =~ "FluxVale Storybook"
    end

    test "404s indistinguishably from absent when disabled" do
      restore = Application.get_env(:flux_vale, :storybook_enabled)
      Application.put_env(:flux_vale, :storybook_enabled, false)
      on_exit(fn -> Application.put_env(:flux_vale, :storybook_enabled, restore) end)

      conn = get(build_conn(), "/storybook")

      assert conn.status == 404
    end
  end
end
