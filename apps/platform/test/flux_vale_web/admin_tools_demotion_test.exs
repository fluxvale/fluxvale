defmodule FluxValeWeb.AdminToolsDemotionTest do
  @moduledoc false

  # The demotion window on the generated tools (#671): the custom
  # console's per-event seam (AdminChrome's hooks, extracted into
  # FluxValeWeb.AdminDemotionGate) now rides the ash_admin and
  # live_dashboard live_sessions after AdminGate, so a platform admin
  # demoted mid-session no longer acts through an already-open tab on
  # those surfaces' view-level events. Each test proves the wiring
  # first (the event moves the DOM under a live admin session), then
  # demotes under the socket, then fires the same event and pins the
  # refusal: the handler never runs, the DOM keeps its last permitted
  # state. The refusal FLASH has no renderer on these surfaces (the
  # vendor layouts ship no flash group), so the DOM effect is the
  # observable — the copy itself is pinned byte-for-byte by the
  # custom-surface suites that share the seam.
  #
  # Honest boundary, stated where it matters: the seam sees
  # VIEW-targeted events only. AshAdmin's save/destroy forms target
  # their own LiveComponents (`phx-target={@myself}`) and LiveView
  # routes cid events straight to the component — no view-level hook
  # sees them. That residue is disclosed on #671, not covered here.

  use FluxValeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias AshAuthentication.Jwt
  alias FluxVale.Identity.User

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
      conn = admin_session_conn(conn, admin)

      {:ok, view, _html} = live(conn, "/admin/ash")

      # Wiring proof: toggle_sidebar is a view-level event on the
      # AshAdmin page, and under a live admin session it moves the
      # sidebar DOM.
      assert has_element?(view, "aside.-translate-x-full")
      render_click(view, "toggle_sidebar", %{})
      assert has_element?(view, "aside.translate-x-0")
      refute has_element?(view, "aside.-translate-x-full")

      demote!(admin)

      # The same event is refused: the seam re-resolves the actor from
      # the session, finds no platform admin, and halts the event
      # before AshAdmin's handler — the sidebar keeps the state the
      # last permitted event left it in.
      render_click(view, "toggle_sidebar", %{})

      assert has_element?(view, "aside.translate-x-0")
      refute has_element?(view, "aside.-translate-x-full")
    end

    test "refuses the demoted actor's events on the LiveDashboard surface", %{
      conn: conn,
      admin: admin
    } do
      conn = admin_session_conn(conn, admin)

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

      demote!(admin)

      # The same event is refused: the menu keeps the last permitted
      # rate. This surface's own tick is an info message, so it halts
      # the same way — the dashboard stops answering and stops
      # following live data under the dead session.
      render_change(view, "select_refresh", %{"refresh" => "1"})

      assert has_element?(view, "#refresher option[value='5'][selected]")
      refute has_element?(view, "#refresher option[value='1'][selected]")
    end
  end

  # Demote the actor under the live session. User carries no role-write
  # action and Ash.Seed is create-only, so this one precondition rides
  # the data layer directly (tests own their preconditions; the
  # per-event gate is what the tests pin) — the wallet surface's
  # demotion-suite idiom.
  defp demote!(admin) do
    query = from(u in "users", where: u.id == ^Ecto.UUID.dump!(admin.id))
    {updated, nil} = FluxVale.Repo.update_all(query, set: [platform_role: "user"])
    assert updated == 1
  end

  defp admin_session_conn(conn, user) do
    {:ok, token, _claims} = Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end
end
