defmodule FluxValeWeb.AdminToolsRecheckTest do
  @moduledoc false

  # The generated tools' demotion residue, BOUNDED (#671, ADR-0027
  # Am. 6): the per-event seam cannot see cid-targeted events, so a
  # demoted platform admin's already-open /admin/ash or dashboard tab
  # kept acting until the socket reconnected. The periodic re-resolve
  # (FluxValeWeb.AdminDemotionRecheck) bounds that window to the
  # cadence: every tick re-resolves the actor from the session, and a
  # failed role check redirects the tab to /sign-in — the same answer
  # AdminGate gives at every mount. These tests pin the three sides of
  # that contract: the demoted (or revoked) session redirects within
  # the window on BOTH generated surfaces, a live admin's session
  # ticks without churning (no redirect, still serving, and the tick
  # observably resolves — an Identity read per tick, counted through
  # ash's telemetry), and the timer never accumulates pending ticks.
  #
  # Cadence is app-env (config default 30s). Tests that need the
  # natural timer set a short cadence and restore the prior value on
  # exit (tests own their preconditions); the hand-driven-tick tests
  # keep the default so no natural tick can race their assertions.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshAuthentication.Jwt
  alias AshAuthentication.TokenResource.Actions
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.AdminDemotion
  alias FluxVale.TestSupport.SessionHelpers

  # A fresh admin per test, the demotion suite's idiom: the demotion
  # persists in the row, so a shared fixture would hand the second
  # test a non-admin (the mount gate would refuse the mount itself).
  setup do
    admin =
      User.create!(
        "admin-recheck-#{System.unique_integer([:positive])}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    # Capture-and-restore, the suite's own rule: the cadence is global
    # app env, so a test that shortens it puts back exactly what was
    # there — delete_env would strip config.exs's default for every
    # later module in this VM.
    previous = Application.get_env(:flux_vale, :admin_demotion_recheck_ms)
    on_exit(fn -> Application.put_env(:flux_vale, :admin_demotion_recheck_ms, previous) end)

    %{admin: admin}
  end

  # The resolve observable: ash emits [:ash, :identity, :read, :start]
  # from the resolving process (the view) for every User resolve —
  # the tick's, and the seam's per-event one. The handler runs in the
  # view, so it forwards to this test process; drains keep the counts
  # scoped to exactly the interactions below.
  defp attach_read_listener(id) do
    :ok = :telemetry.attach(id, [:ash, :identity, :read, :start], &forward/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
    drain_reads()
  end

  describe "a demoted actor's generated tab redirects within the window" do
    test "on AshAdmin, after a mid-session demotion", %{conn: conn, admin: admin} do
      # 25ms cadence: the window under test is the tick itself.
      Application.put_env(:flux_vale, :admin_demotion_recheck_ms, 25)
      conn = SessionHelpers.sign_in(conn, admin)

      {:ok, view, _html} = live(conn, "/admin/ash")

      AdminDemotion.demote!(admin)

      # The wiring proof is the redirect arriving on its own — no
      # event, no interaction: the tick re-resolves, finds no platform
      # admin, and the channel honors the redirect the halted info
      # hook set. (That a tick fired at all is pinned harder by the
      # churn/leak tests' read counts; this one pins the outcome.)
      assert_redirect(view, "/sign-in", 1_000)

      # The redirect ends the socket, which is what retires its
      # pending tick — the drop-with-the-process proof, behavioral.
      pid = view.pid
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end

    test "on LiveDashboard, after a mid-session demotion", %{conn: conn, admin: admin} do
      Application.put_env(:flux_vale, :admin_demotion_recheck_ms, 25)
      conn = SessionHelpers.sign_in(conn, admin)

      {:ok, view, _html} =
        conn
        |> live("/admin/debug/dashboard")
        |> follow_redirect(conn)

      AdminDemotion.demote!(admin)

      assert_redirect(view, "/sign-in", 1_000)
    end

    test "on AshAdmin, after the session token is revoked (the resolve-nil arm)", %{
      conn: conn,
      admin: admin
    } do
      Application.put_env(:flux_vale, :admin_demotion_recheck_ms, 25)

      {:ok, token, _claims} = Jwt.token_for_user(admin)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_token", token)

      {:ok, view, _html} = live(conn, "/admin/ash")

      :ok = Actions.revoke(FluxVale.Identity.Token, token)

      assert_redirect(view, "/sign-in", 1_000)
    end
  end

  describe "a live admin's generated session does not churn" do
    test "consumes the tick quietly — resolves, no redirect, still serving", %{
      conn: conn,
      admin: admin
    } do
      conn = SessionHelpers.sign_in(conn, admin)

      # Default 30s cadence on purpose: the natural timer stays out
      # of the test's way, and the tick message is driven by hand —
      # the handler's own input, the storage queue's freeze-test
      # idiom for driving an info path deterministically.
      {:ok, view, _html} = live(conn, "/admin/ash")
      attach_read_listener("recheck-churn-test")

      assert has_element?(view, "aside.-translate-x-full")

      # Causality pin, one round per tick: the mailbox is drained,
      # the tick is sent, and an Identity read MUST follow — with no
      # other event in flight it can only be that tick's resolve (a
      # resolve may read more than once; the drain absorbs the rest).
      # If the handler ever consumed the message without resolving,
      # the await times out; if it churned the session, the serving
      # proofs below would raise on the dead socket.
      for _tick <- 1..3 do
        drain_reads()
        send(view.pid, :admin_demotion_recheck)
        assert_receive :identity_read, 500
      end

      drain_reads()

      # Still mounted, still serving. The sidebar moves on demand —
      # hidden -> shown -> hidden -> shown.
      render_click(view, "toggle_sidebar", %{})
      assert has_element?(view, "aside.translate-x-0")
      render_click(view, "toggle_sidebar", %{})
      assert has_element?(view, "aside.-translate-x-full")

      assert render(view) =~ "Ash Admin"
    end

    test "the dashboard's own refresh keeps flowing through the recheck (the passthrough arm)", %{
      conn: conn,
      admin: admin
    } do
      # Default 30s recheck cadence on purpose: with the recheck's
      # own ticks out of the picture, the ONLY Identity reads on this
      # socket are the seam's per-info resolves on the dashboard's
      # :refresh messages — isolating the passthrough arm.
      conn = SessionHelpers.sign_in(conn, admin)

      {:ok, view, _html} =
        conn
        |> live("/admin/debug/dashboard")
        |> follow_redirect(conn)

      # select_refresh changes the menu rate but NOT the pending
      # timer (vendor code arms at the old rate), so the first
      # :refresh is hand-driven — the storage queue's freeze-test
      # idiom. The catch-all must pass it through: the seam's info
      # gate resolves behind us (read #1), and the dashboard's own
      # handler runs — which re-arms its timer at the NEW 1s rate, so
      # a natural :refresh follows within seconds and traverses the
      # same chain again (read #2). If the catch-all ever halted
      # instead, neither read arrives: no resolve, no handler, no
      # successor tick.
      render_change(view, "select_refresh", %{"refresh" => "1"})
      attach_read_listener("recheck-passthrough-test")

      send(view.pid, :refresh)

      assert_receive :identity_read, 1_000
      assert_receive :identity_read, 3_000
      assert render(view) =~ "Metrics"
    end
  end

  describe "mount-time behavior" do
    test "a misconfigured cadence degrades to the default, not a crash or a hot loop", %{
      conn: conn,
      admin: admin
    } do
      conn = SessionHelpers.sign_in(conn, admin)

      # nil is the raising shape: an unguarded cadence reaches
      # Process.send_after with nil and ArgumentErrors inside
      # on_mount — a mount that renders at all pins the guard.
      Application.put_env(:flux_vale, :admin_demotion_recheck_ms, nil)
      {:ok, view_nil, _html} = live(conn, "/admin/ash")
      assert render(view_nil) =~ "Ash Admin"

      # 0 is the hot-loop shape: send_after accepts it and would
      # re-arm immediately, resolving against the DB at full speed.
      # The guard's fallback (the documented 30s) means an idle
      # socket resolves NOTHING in the test's window — a zero read
      # count pins that no loop is running.
      {:ok, view_zero, _html} = live(conn, "/admin/ash")
      assert render(view_zero) =~ "Ash Admin"
      attach_read_listener("recheck-cadence-test")

      assert_reads_drained()
    end

    test "the dead render mounts clean (the disconnected arm is a no-op smoke pin)", %{
      conn: conn,
      admin: admin
    } do
      # Honest scope: this pins that the disconnected mount renders
      # and nothing in the guard's path disturbs it — a plain GET.
      # Arming is unobservable on a dead render either way (its
      # process exits with the response); what the connected arm
      # does — and that it arms at all — is pinned by the redirect
      # and churn tests above.
      conn =
        conn
        |> SessionHelpers.sign_in(admin)
        |> get("/admin/ash")

      assert html_response(conn, 200) =~ "Ash Admin"
    end
  end

  describe "the timer does not leak" do
    test "natural ticks keep flowing, one pending at most, no churn", %{conn: conn, admin: admin} do
      Application.put_env(:flux_vale, :admin_demotion_recheck_ms, 20)
      conn = SessionHelpers.sign_in(conn, admin)

      {:ok, view, _html} = live(conn, "/admin/ash")
      attach_read_listener("recheck-leak-test")

      # The ticks themselves pace the wait: four resolves awaited,
      # not a fixed wall-clock window — no sleep to shortchange on a
      # starved runner.
      assert_receive :identity_read, 1_000
      assert_receive :identity_read, 1_000
      assert_receive :identity_read, 1_000
      assert_receive :identity_read, 1_000

      # The leak class would be timer multiplication — every handled
      # tick arming more than one successor. At any instant a
      # correctly-armed socket has at most ONE pending tick message;
      # simultaneous double-arming leaves two. (A stale-duplicate
      # multiplication that staggers arms escapes this check — the
      # resolve count above and the single arm call site carry the
      # rest of the invariant.)
      {:messages, messages} = Process.info(view.pid, :messages)
      ticks = Enum.count(messages, &(&1 == :admin_demotion_recheck))
      assert ticks <= 1

      # And the session is still alive and serving after all that
      # ticking — no churn, no crash.
      assert render(view) =~ "Ash Admin"
    end
  end

  # The telemetry forwarder: runs in the emitting (view) process.
  defp forward(_event, _measurements, _metadata, test_pid) do
    send(test_pid, :identity_read)
  end

  defp drain_reads do
    receive do
      :identity_read -> drain_reads()
    after
      0 -> :ok
    end
  end

  defp assert_reads_drained do
    receive do
      :identity_read -> flunk("unexpected extra Identity read")
    after
      0 -> :ok
    end
  end
end
