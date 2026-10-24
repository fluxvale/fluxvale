defmodule FluxValeWeb.InstanceLive.DavSnippetTest do
  @moduledoc false

  # #253's pure halves: the OS-detection helper (representative user
  # agents — the helper, not the browser; the .DavOsDefault hook is a
  # one-line push that these tests don't need) and the per-platform
  # step sequences' shape. The rendered-panel assertions (real URL and
  # username inline, tab switching) live in the show-page LiveView
  # tests.

  use ExUnit.Case, async: true

  alias FluxValeWeb.InstanceLive.DavSnippet

  @values %{
    remote: "fluxvale-example",
    url: "https://example.fluxvale.lvh.me/dav",
    username: "fluxvale",
    password: "YOUR_PASSWORD"
  }

  describe "guess_platform/1 — representative user agents" do
    test "Windows: UA-CH platform, legacy navigator.platform, full UA" do
      # navigator.userAgentData.platform (Chromium, UA-CH reduced)
      assert DavSnippet.guess_platform("Windows") == :windows
      # navigator.platform (every Windows browser)
      assert DavSnippet.guess_platform("Win32") == :windows
      assert DavSnippet.guess_platform("Win64") == :windows
      # A full UA string, if the hook ever falls back that far
      assert DavSnippet.guess_platform(
               "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
             ) == :windows
    end

    test "macOS: UA-CH platform, navigator.platform, Darwin, full UA" do
      assert DavSnippet.guess_platform("macOS") == :macos
      assert DavSnippet.guess_platform("MacIntel") == :macos
      # "darwin" contains "win" — the mac match must run first
      assert DavSnippet.guess_platform("Darwin") == :macos

      assert DavSnippet.guess_platform(
               "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15"
             ) == :macos
    end

    test "Linux: navigator.platform variants and a full UA" do
      assert DavSnippet.guess_platform("Linux x86_64") == :linux
      assert DavSnippet.guess_platform("Linux armv8l") == :linux

      assert DavSnippet.guess_platform(
               "Mozilla/5.0 (X11; Linux x86_64; rv:132.0) Gecko/20100101 Firefox/132.0"
             ) == :linux
    end

    test "platforms no tab serves stay nil — the Linux default stands" do
      # Android and iOS have no rclone quick-start; the caller keeps
      # its default rather than guessing a desktop OS for a phone.
      assert DavSnippet.guess_platform("Android") == nil
      assert DavSnippet.guess_platform("iPhone") == nil
      assert DavSnippet.guess_platform("iPad") == nil
      assert DavSnippet.guess_platform("CrOS") == nil
      assert DavSnippet.guess_platform("") == nil
      assert DavSnippet.guess_platform(nil) == nil
    end

    test "a non-string payload stays nil — a hooked client can push anything" do
      # The event handler feeds the raw socket payload here; a raise
      # would take the whole LiveView down (hostile-pass finding).
      assert DavSnippet.guess_platform(123) == nil
      assert DavSnippet.guess_platform(["Win32"]) == nil
      assert DavSnippet.guess_platform(%{"platform" => "Win32"}) == nil
    end
  end

  describe "platform_key/1" do
    test "maps the phx-value strings onto the fixed tab keys" do
      assert DavSnippet.platform_key("windows") == :windows
      assert DavSnippet.platform_key("macos") == :macos
      assert DavSnippet.platform_key("linux") == :linux
    end

    test "anything else is nil — a stale click keeps the current tab" do
      assert DavSnippet.platform_key("windows ") == nil
      assert DavSnippet.platform_key("WINDOWS") == nil
      assert DavSnippet.platform_key("dos") == nil
    end
  end

  describe "steps/2" do
    test "every platform is the same five steps in the same order" do
      for %{key: platform} <- DavSnippet.platforms() do
        steps = DavSnippet.steps(platform, @values)

        assert Enum.map(steps, & &1.title) == [
                 "Install rclone (only if needed)",
                 "Create the local source",
                 "Connect",
                 "Verify",
                 "Copy"
               ]
      end
    end

    test "every step carries a command, and --obscure rides every connect line" do
      for %{key: platform} <- DavSnippet.platforms() do
        for step <- DavSnippet.steps(platform, @values) do
          assert is_binary(step.command) and step.command != ""
        end

        steps = DavSnippet.steps(platform, @values)
        connect = Enum.at(steps, 2)
        assert connect.command =~ "--obscure"
        assert connect.command =~ "url #{@values.url} vendor rclone user #{@values.username}"
      end
    end

    test "Windows folds the connect command to one line; the others continue with a backslash" do
      windows_steps = DavSnippet.steps(:windows, @values)
      windows_connect = Enum.at(windows_steps, 2)
      refute windows_connect.command =~ "\n"

      for platform <- [:macos, :linux] do
        steps = DavSnippet.steps(platform, @values)
        connect = Enum.at(steps, 2)
        assert connect.command =~ "webdav \\\n    url "
      end
    end
  end
end
