defmodule FluxValeWeb.ReturnPathTest do
  @moduledoc false

  # The open-redirect guard behind the sign-in return path (#462): only
  # local request paths may become redirect targets, everything else is
  # silently ignored. The controller and the gate ride the same
  # predicate — this table is the notion's single ground truth.

  use FluxValeWeb.ConnCase, async: true

  describe "local?/1 — the guard" do
    test "accepts local request paths" do
      assert FluxValeWeb.ReturnPath.local?("/feedback/some-post")
      assert FluxValeWeb.ReturnPath.local?("/")
      assert FluxValeWeb.ReturnPath.local?("/feedback/new")
      # Query and fragment ride along — the invitation token, the
      # device-flow anchor — the value stays one local path.
      assert FluxValeWeb.ReturnPath.local?("/invitations/accept?token=abc")
      assert FluxValeWeb.ReturnPath.local?("/settings/developer#device-sign-ins")
    end

    test "refuses the open-redirect shapes" do
      # protocol-relative: a host in the authority position
      refute FluxValeWeb.ReturnPath.local?("//evil.com")
      # backslash variants: browsers normalize \\ to // for special
      # schemes, so a leading /\ introduces an authority the same way
      # (verified against Chromium's URL parser, #462 review)
      refute FluxValeWeb.ReturnPath.local?("/\\evil.com")
      refute FluxValeWeb.ReturnPath.local?("/\\evil.com:8080/x")
      refute FluxValeWeb.ReturnPath.local?("/\\//evil.com")
      refute FluxValeWeb.ReturnPath.local?("\\\\evil.com")
      # mid-string shapes Phoenix's redirect(to:) raises on (#462
      # review): the guard must be sufficient, or a valid sign-in ends
      # in a 500 instead of a redirect
      refute FluxValeWeb.ReturnPath.local?("/feedback/a\\b")
      refute FluxValeWeb.ReturnPath.local?("/x/%09y")
      refute FluxValeWeb.ReturnPath.local?("/x/\ty")
      # newline shapes Plug's header write raises on (#462 CodeRabbit
      # round): same sufficiency rule
      refute FluxValeWeb.ReturnPath.local?("/feedback\nx")
      refute FluxValeWeb.ReturnPath.local?("/feedback\rx")
      # absolute schemes, http and beyond
      refute FluxValeWeb.ReturnPath.local?("https://evil.com")
      refute FluxValeWeb.ReturnPath.local?("http://evil.com/phish")
      # script URLs
      refute FluxValeWeb.ReturnPath.local?("javascript:alert(1)")
      # whitespace-prefixed (some clients strip it before resolving)
      refute FluxValeWeb.ReturnPath.local?(" //evil.com")
      refute FluxValeWeb.ReturnPath.local?("\n//evil.com")
      # relative paths without the leading slash
      refute FluxValeWeb.ReturnPath.local?("feedback/some-post")
      refute FluxValeWeb.ReturnPath.local?("")
    end

    test "refuses non-strings (a missing or malformed param)" do
      refute FluxValeWeb.ReturnPath.local?(nil)
      refute FluxValeWeb.ReturnPath.local?(42)
      refute FluxValeWeb.ReturnPath.local?(%{"return_to" => "/x"})
      refute FluxValeWeb.ReturnPath.local?(["/x"])
    end
  end

  describe "safe/1 — the silent-ignore fallback" do
    test "passes a local path through unchanged" do
      assert FluxValeWeb.ReturnPath.safe("/feedback/some-post") == "/feedback/some-post"
    end

    test "answers nil for everything the guard refuses" do
      assert FluxValeWeb.ReturnPath.safe("//evil.com") == nil
      assert FluxValeWeb.ReturnPath.safe("https://evil.com") == nil
      assert FluxValeWeb.ReturnPath.safe(nil) == nil
    end
  end

  describe "sign_in_path/1 — the link builder" do
    test "carries a local target as the return_to query param" do
      assert FluxValeWeb.ReturnPath.sign_in_path("/feedback/some-post") ==
               "/sign-in?return_to=%2Ffeedback%2Fsome-post"
    end

    test "falls back to plain /sign-in for a non-local target" do
      assert FluxValeWeb.ReturnPath.sign_in_path("//evil.com") == "/sign-in"
      assert FluxValeWeb.ReturnPath.sign_in_path(nil) == "/sign-in"
    end
  end
end
