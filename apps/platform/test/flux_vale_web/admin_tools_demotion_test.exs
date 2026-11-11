defmodule FluxValeWeb.AdminToolsDemotionTest do
  @moduledoc false

  # The demotion window on the generated tools (#671): the custom
  # console's per-event seam (AdminChrome's hooks, extracted into
  # FluxValeWeb.AdminDemotionGate) now rides the ash_admin and
  # live_dashboard live_sessions after AdminGate, so a platform admin
  # demoted mid-session no longer acts through an already-open tab on
  # those surfaces' VIEW-level events. Each test proves the wiring
  # first (the event moves the DOM under a live admin session), then
  # kills the session under the socket (demotion or token
  # revocation), then fires the same event and pins the refusal: the
  # handler never runs, the server-side DOM keeps its last permitted
  # state. The refusal FLASH has no renderer on these surfaces (the
  # vendor layouts ship no flash group), so the refusal is silent and
  # the DOM effect is the observable — the copy itself is pinned
  # byte-for-byte by the custom-surface suites that share the seam.
  # In a real browser a silent refusal on a form control LOOKS
  # applied (the select shows the user's pick) while the server
  # ignores it — the seam's honesty lives server-side.
  #
  # The generated tools' demotion residue, BOUNDED (#671, ADR-0027
  # Am. 6): the per-event seam cannot see cid-targeted events, so a
  # demoted platform admin's already-open /admin/ash or dashboard tab
  # kept acting until the socket reconnected. The periodic re-resolve
  # bounds the window to one cadence; its own suite
  # (admin_tools_recheck_test.exs) pins that side.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshAuthentication.Jwt
  alias AshAuthentication.TokenResource.Actions
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.AdminDemotion
  alias FluxVale.TestSupport.SessionHelpers

  # A fresh admin per test: the demotion persists in the row, so a
  # shared fixture would hand the second test a non-admin (the mount
  # gate would refuse the mount itself).
  setup do
    admin =
      User.create!(
        "admin-demotion-#{System.unique_integer([:positive])}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin}
  end

  describe "a mid-session demotion on the generated tools (#671)" do
    test "refuses the demoted actor's events on AshAdmin's view-level surface", %{
      conn: conn,
      admin: admin
    } do
      conn = SessionHelpers.sign_in(conn, admin)

      {:ok, view, _html} = live(conn, "/admin/ash")

      # Wiring proof: toggle_sidebar is a view-level event on the
      # AshAdmin page, and under a live admin session it moves the
      # sidebar DOM.
      assert has_element?(view, "aside.-translate-x-full")
      render_click(view, "toggle_sidebar", %{})
      assert has_element?(view, "aside.translate-x-0")
      refute has_element?(view, "aside.-translate-x-full")

      AdminDemotion.demote!(admin)

      # The same event is refused: the seam re-resolves the actor from
      # the session, finds no platform admin, and halts the event
      # before AshAdmin's handler — silently (no flash renderer in
      # the vendor layout); the server keeps the state the last
      # permitted event left.
      render_click(view, "toggle_sidebar", %{})
      assert has_element?(view, "aside.translate-x-0")
      refute has_element?(view, "aside.-translate-x-full")
    end

    test "refuses the demoted actor's events on the LiveDashboard surface", %{
      conn: conn,
      admin: admin
    } do
      conn = SessionHelpers.sign_in(conn, admin)

      # The index live-redirects to Home, and pages redirect again to
      # pin their nav param — follow_redirect lands wherever the
      # dashboard settles.
      {:ok, view, _html} =
        conn
        |> live("/admin/debug/dashboard")
        |> follow_redirect(conn)

      # Wiring proof: the refresher form is view-level (phx-change,
      # no phx-target), and under a live admin session a rate change
      # re-renders the menu with the new rate selected.
      assert has_element?(view, "#refresher option[value='15'][selected]")

      render_change(view, "select_refresh", %{"refresh" => "5"})

      assert has_element?(view, "#refresher option[value='5'][selected]")

      AdminDemotion.demote!(admin)

      # The same event is refused — silently; the menu keeps the last
      # permitted rate, and the tick (an info message) halts the same
      # way, so the dashboard stops answering and stops following
      # under the dead session.
      render_change(view, "select_refresh", %{"refresh" => "1"})

      assert has_element?(view, "#refresher option[value='5'][selected]")
      refute has_element?(view, "#refresher option[value='1'][selected]")
    end
  end

  describe "a revoked session on the generated tools (the resolve-nil arms)" do
    test "refuses the actor's events after the session token is revoked", %{
      conn: conn,
      admin: admin
    } do
      {:ok, token, _claims} = Jwt.token_for_user(admin)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_token", token)

      {:ok, view, _html} = live(conn, "/admin/ash")

      # Wiring proof: the view-level event moves the sidebar DOM
      # while the token still resolves.
      assert has_element?(view, "aside.-translate-x-full")
      render_click(view, "toggle_sidebar", %{})
      assert has_element?(view, "aside.translate-x-0")

      # The framework revoke path (the user_auth suite's idiom): the
      # resolve's token-presence check stops passing — the event
      # gate's other refusal arm.
      :ok = Actions.revoke(FluxVale.Identity.Token, token)

      render_click(view, "toggle_sidebar", %{})

      assert has_element?(view, "aside.translate-x-0")
      refute has_element?(view, "aside.-translate-x-full")
    end

    test "halts a revoked session's notification quietly on the LiveDashboard tick", %{
      conn: conn,
      admin: admin
    } do
      {:ok, token, _claims} = Jwt.token_for_user(admin)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_token", token)

      {:ok, view, _html} =
        conn
        |> live("/admin/debug/dashboard")
        |> follow_redirect(conn)

      :ok = Actions.revoke(FluxVale.Identity.Token, token)

      # The dashboard's own tick, driven the way the storage queue's
      # freeze test drives its notification: the info gate resolves
      # first, the token no longer passes, and the halt is quiet —
      # the view's own :refresh handler never runs (no crash, no
      # data advance; the quiet-freeze class the demoted-actor tests
      # pin behaviorally one arm over).
      send(view.pid, :refresh)

      assert render(view) =~ "Metrics"

      # The event arm of the same dead session: refused, silently.
      render_change(view, "select_refresh", %{"refresh" => "1"})

      assert has_element?(view, "#refresher option[value='15'][selected]")
    end
  end
end
