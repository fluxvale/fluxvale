defmodule FluxVale.EdgeTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias FluxVale.Edge

  describe "probe_request?/1 — the settled must-NOT-count list" do
    test "kube-probe never counts as traffic" do
      assert Edge.probe_request?("kube-probe/1.29")
    end

    test "the honest monitor fleet is filtered case-insensitively" do
      assert Edge.probe_request?("UptimeRobot/2.0 (http://www.uptimerobot.com/)")
      assert Edge.probe_request?("prometheus/2.54")
      assert Edge.probe_request?("Better Uptime/1.0")
    end

    test "a browser, curl, and rclone are real traffic" do
      refute Edge.probe_request?("Mozilla/5.0 (X11; Linux x86_64)")
      refute Edge.probe_request?("curl/8.5.0")
      refute Edge.probe_request?("rclone/v1.75.2")
    end

    test "a nil user-agent is NOT a probe — filtered lists beat paranoid defaults" do
      refute Edge.probe_request?(nil)
    end
  end
end
