defmodule FluxValeWeb.AdminPeopleLiveTest do
  @moduledoc false

  # The people surface (#501): the invitation list, the invite form,
  # and the per-invitation support actions. The route gates here are
  # the shared live_session's arms (the anonymous 302 and the non-admin
  # 403, pinned once); the write paths are additionally pinned at the
  # domain seam with a non-admin actor (Forbidden), because the route
  # gate is the only thing standing between a non-admin and these views.
  # Mail assertions ride the TestInbox capture (the test+ address
  # pattern): the default deliver runs inside the LiveView process, so
  # the captured mailbox is the observable.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import FluxVale.TestSupport.UserInviteHelpers

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.SessionHelpers

  require Ash.Query

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    admin =
      User.create!(
        "admin-people-admin-#{@n}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin), bare_conn: conn}
  end

  defp unique_address(tag \\ "x") do
    "test+people-#{tag}-#{System.unique_integer()}@fluxvale.com"
  end

  # A pending invite through the real operation with the admin actor —
  # the default deliver captures into the TestInbox, so the raw accept
  # token is recoverable from the mail body (the accept link IS the
  # credential the withdraw is about to kill).
  defp pending_invite!(admin, address \\ nil) do
    address = address || unique_address()
    {:ok, user, raw} = Identity.invite_user(admin, address)
    {user, raw}
  end

  defp accepted_invite!(admin) do
    {user, raw} = pending_invite!(admin)
    {:ok, _accepted, _jwt} = Identity.accept_invitation(raw)
    {user, raw}
  end

  defp token_from_mail(address) do
    {:ok, mail} = FluxVale.TestInbox.latest_mail(address)

    case Regex.run(~r/token=([A-Za-z0-9_-]+)/, mail.text_body) do
      [_all, token] -> token
      nil -> flunk("no accept link in the invitation mail for #{address}")
    end
  end

  defp text_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  describe "the invitation list" do
    test "an empty surface says honestly that accounts without an invitation story are not its business",
         %{conn: conn} do
      # A normal account exists and must not put the page in business.
      User.create!("no-story-#{@n}@fluxvale.com", %{}, authorize?: false)

      {:ok, view, _html} = live(conn, "/admin/people")

      assert has_element?(view, "[data-testid='admin-people']")
      assert has_element?(view, "[data-testid='admin-people-list'] p", "No invitations yet.")
      assert has_element?(view, "[data-testid='admin-people-list']", "not this page's business")
      refute has_element?(view, "[data-testid^='admin-people-email-']")
    end

    test "lists invited, accepted, and withdrawn rows with their lifecycle stamps", %{
      conn: conn,
      admin: admin
    } do
      {pending, _raw} = pending_invite!(admin)
      {accepted, _accepted_raw} = accepted_invite!(admin)
      {withdrawn, _withdrawn_raw} = pending_invite!(admin)
      assert {:ok, _withdrawn} = Identity.withdraw_invite(admin, withdrawn)

      {:ok, view, _html} = live(conn, "/admin/people")

      # One lifecycle badge per row, in the invite vocabulary.
      assert has_element?(view, "[data-testid='admin-people-state-#{pending.id}']", "Pending")
      assert has_element?(view, "[data-testid='admin-people-state-#{accepted.id}']", "Accepted")
      assert has_element?(view, "[data-testid='admin-people-state-#{withdrawn.id}']", "Withdrawn")

      # The stamps support acts on: the invited and expires stamps ride
      # every invited row, the accepted stamp lands only on acceptance,
      # the withdrawn stamp only on withdrawal.
      refute text_of(view, "[data-testid='admin-people-invited-#{pending.id}']") == ""
      refute text_of(view, "[data-testid='admin-people-expires-#{pending.id}']") == ""
      assert text_of(view, "[data-testid='admin-people-accepted-#{pending.id}']") == ""
      assert text_of(view, "[data-testid='admin-people-withdrawn-#{pending.id}']") == ""

      refute text_of(view, "[data-testid='admin-people-accepted-#{accepted.id}']") == ""
      assert text_of(view, "[data-testid='admin-people-withdrawn-#{accepted.id}']") == ""

      refute text_of(view, "[data-testid='admin-people-withdrawn-#{withdrawn.id}']") == ""
      assert text_of(view, "[data-testid='admin-people-accepted-#{withdrawn.id}']") == ""

      # Expiry is only meaningful while the link can still be used:
      # closed rows leave the cell empty.
      refute has_element?(view, "[data-testid='admin-people-expires-#{accepted.id}']")
      refute has_element?(view, "[data-testid='admin-people-expires-#{withdrawn.id}']")

      # The address column is the invitation's address.
      assert text_of(view, "[data-testid='admin-people-email-#{pending.id}']") ==
               to_string(pending.email)
    end

    test "rows run newest-first by the invited stamp", %{conn: conn, admin: admin} do
      {older, _raw} = pending_invite!(admin)
      {newer, _raw} = pending_invite!(admin)

      {:ok, view, _html} = live(conn, "/admin/people")

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.query(document, "[data-testid^='admin-people-email-']")

      addresses =
        for match <- Enum.to_list(matches) do
          text = LazyHTML.text(match)
          String.trim(text)
        end

      assert addresses == Enum.map([newer.email, older.email], &to_string/1)
    end

    test "an expired invite reads honestly and still offers the reinvite lever", %{
      conn: conn
    } do
      # Actions cannot backdate the window, so seed! is the sanctioned
      # bypass (the helper's own contract).
      expired = expired_invited_user!(unique_address("expired"))

      {:ok, view, _html} = live(conn, "/admin/people")

      # The expired chip carries its own tone AND a non-color cue (the
      # clock), so it never shares both tone and shape with another
      # state in either theme.
      assert has_element?(view, "[data-testid='admin-people-state-#{expired.id}']", "Expired")
      assert has_element?(view, "[data-testid='admin-people-state-#{expired.id}'] .hero-clock")

      assert has_element?(view, "[data-testid='admin-people-reinvite-#{expired.id}']")
      refute has_element?(view, "[data-testid='admin-people-withdraw-#{expired.id}']")
    end

    test "the list caps at the latest 100 and says so", %{conn: conn} do
      # Precondition volume through the real action (nil actor +
      # authorize?: false, the seeds posture; the deliver discards).
      {:ok, oldest_user, _raw} =
        Identity.invite_user(
          nil,
          unique_address("oldest"),
          fn _to, _url -> {:ok, :discarded} end,
          authorize?: false
        )

      invited =
        for _n <- 1..100 do
          {:ok, user, _raw} =
            Identity.invite_user(
              nil,
              unique_address(),
              fn _to, _url -> {:ok, :discarded} end,
              authorize?: false
            )

          user
        end

      newest = List.last(invited)

      {:ok, view, _html} = live(conn, "/admin/people")

      assert has_element?(view, "[data-testid='admin-people-capped']", "latest 100")
      assert has_element?(view, "[data-testid='admin-people-email-#{newest.id}']")
      refute has_element?(view, "[data-testid='admin-people-email-#{oldest_user.id}']")
    end

    test "a live account with no invitation story never appears", %{conn: conn, admin: admin} do
      outsider = SessionHelpers.user!()
      {pending, _raw} = pending_invite!(admin)

      {:ok, view, _html} = live(conn, "/admin/people")

      assert has_element?(view, "[data-testid='admin-people-email-#{pending.id}']")
      refute has_element?(view, "[data-testid='admin-people-email-#{outsider.id}']")
    end

    test "search narrows this list by email and never reaches past it", %{
      conn: conn,
      admin: admin
    } do
      {alpha, _raw} = pending_invite!(admin, unique_address("alpha"))
      {beta, _raw} = pending_invite!(admin, unique_address("beta"))
      outsider = SessionHelpers.user!()

      {:ok, view, _html} = live(conn, "/admin/people")

      render_change(view, "search", %{"search" => %{"query" => "alpha"}})

      assert has_element?(view, "[data-testid='admin-people-email-#{alpha.id}']")
      refute has_element?(view, "[data-testid='admin-people-email-#{beta.id}']")

      # The scope holds: a live account's address is not a match, even
      # though the search rides the same users table.
      render_change(view, "search", %{"search" => %{"query" => to_string(outsider.email)}})

      assert has_element?(view, "[data-testid='admin-people-list'] p", "No invitation matches")

      # Clearing the search hands the whole list back.
      render_change(view, "search", %{"search" => %{"query" => ""}})

      assert has_element?(view, "[data-testid='admin-people-email-#{alpha.id}']")
      assert has_element?(view, "[data-testid='admin-people-email-#{beta.id}']")
    end
  end

  describe "the invite form" do
    test "sending an invite delivers the accept email and lists the row", %{conn: conn} do
      address = unique_address()

      {:ok, view, _html} = live(conn, "/admin/people")

      view
      |> element("#admin-people-invite-form")
      |> render_submit(%{"invite" => %{"email" => address}})

      assert has_element?(view, "#flash-info", "Invite sent")
      assert has_element?(view, "#flash-info", "stays inert")

      # The delivery copy never promises the inbox: it names the
      # resend lever (the operation's deliver is best-effort).
      assert has_element?(view, "#flash-info", "If the email does not arrive")

      [invited] = users_with_email(address)
      assert has_element?(view, "[data-testid='admin-people-state-#{invited.id}']", "Pending")

      # The email went out: the captured mail carries the one-time
      # accept link (the test inbox pattern — the default deliver ran
      # inside the LiveView process).
      {:ok, mail} = FluxVale.TestInbox.latest_mail(address)
      assert mail.text_body =~ "/invites/accept?token="
      assert mail.text_body =~ "works once"
    end

    test "an address with an outstanding invitation re-issues, and the copy names the dead link",
         %{conn: conn, admin: admin} do
      {pending, old_raw} = pending_invite!(admin)
      {:ok, view, _html} = live(conn, "/admin/people")

      view
      |> element("#admin-people-invite-form")
      |> render_submit(%{"invite" => %{"email" => to_string(pending.email)}})

      # The form is the one invite verb, so this was a re-issue; the
      # copy branch says so instead of staying silent about the killed
      # credential.
      assert has_element?(view, "#flash-info", "Reinvite sent")
      assert has_element?(view, "#flash-info", "Any earlier link no longer works")

      new_raw = token_from_mail(to_string(pending.email))
      refute new_raw == old_raw
      assert {:error, :unknown_token} = Identity.resolve_invite_link(old_raw)
      assert {:ok, :pending} = Identity.resolve_invite_link(new_raw)
    end

    test "an invalid address is refused before anything is written", %{conn: conn, admin: admin} do
      {pending, _raw} = pending_invite!(admin)
      {:ok, view, _html} = live(conn, "/admin/people")

      view
      |> element("#admin-people-invite-form")
      |> render_submit(%{"invite" => %{"email" => "not-an-address"}})

      assert has_element?(view, "#flash-error", "does not look like an email address")

      # Nothing was written (delivery only ever follows a committed
      # row), the list is unmoved. The typed value stays in the form on
      # purpose, so the operator sees what they mistyped.
      assert [] = users_with_email("not-an-address")
      assert has_element?(view, "[data-testid='admin-people-email-#{pending.id}']")
    end

    test "a live account's address is refused", %{conn: conn} do
      live_account = SessionHelpers.user!()
      {:ok, view, _html} = live(conn, "/admin/people")

      view
      |> element("#admin-people-invite-form")
      |> render_submit(%{"invite" => %{"email" => live_account.email}})

      assert has_element?(view, "#flash-error", "already has an active account")

      # Refused before the write: the live account is untouched (no
      # invite stamped on it, delivery only follows a committed row).
      [live_account_row] = users_with_email(to_string(live_account.email))

      assert live_account_row
             |> Ash.load!(:invite_state, authorize?: false)
             |> Map.fetch!(:invite_state) == :none
    end
  end

  describe "per-invitation actions" do
    test "reinvite sends a fresh link and the old link dies", %{conn: conn, admin: admin} do
      {pending, old_raw} = pending_invite!(admin)
      {:ok, view, _html} = live(conn, "/admin/people")

      view
      |> element("[data-testid='admin-people-reinvite-#{pending.id}']")
      |> render_click()

      assert has_element?(view, "#flash-info", "Reinvite sent")
      assert has_element?(view, "#flash-info", "Any earlier link no longer works")

      # Delivery is best-effort, so the copy names the resend lever
      # instead of promising the inbox.
      assert has_element?(view, "#flash-info", "If the email does not arrive")

      # The row stays invited (a fresh window), and a second mail is in
      # the inbox carrying a DIFFERENT one-time link.
      assert has_element?(view, "[data-testid='admin-people-state-#{pending.id}']", "Pending")

      new_raw = token_from_mail(to_string(pending.email))
      refute new_raw == old_raw

      # The old link's credential is gone from the row entirely.
      assert {:error, :unknown_token} = Identity.resolve_invite_link(old_raw)
      assert {:ok, :pending} = Identity.resolve_invite_link(new_raw)
    end

    test "accepted accounts are offered neither action, and the domain refuses the reinvite anyway",
         %{conn: conn, admin: admin} do
      {accepted, _raw} = accepted_invite!(admin)
      {:ok, view, _html} = live(conn, "/admin/people")

      refute has_element?(view, "[data-testid='admin-people-reinvite-#{accepted.id}']")
      refute has_element?(view, "[data-testid='admin-people-withdraw-#{accepted.id}']")

      # The button's absence is UX; the domain is the gate. A crafted
      # reinvite at an accepted account refuses with the same shape the
      # invite form reads.
      assert {:error, :already_active} = Identity.invite_user(admin, accepted.email)
    end

    test "withdraw confirms, then the person's link stops working", %{conn: conn, admin: admin} do
      {pending, raw} = pending_invite!(admin)
      {:ok, view, _html} = live(conn, "/admin/people")

      assert {:ok, :pending} = Identity.resolve_invite_link(raw)

      view
      |> element("[data-testid='admin-people-withdraw-#{pending.id}']")
      |> render_click()

      # The consequence panel: the link dies, the account stays inert.
      assert has_element?(view, "[data-testid='destructive-confirm']")
      assert has_element?(view, "[data-testid='destructive-confirm']", "stops working")
      assert has_element?(view, "[data-testid='destructive-confirm']", "remains inert")
      assert has_element?(view, "[data-testid='admin-people-withdraw-confirm']")
      assert has_element?(view, "[data-testid='admin-people-withdraw-cancel']")

      # Cancel is a way out: the panel closes and nothing happened.
      view
      |> element("[data-testid='admin-people-withdraw-cancel']")
      |> render_click()

      refute has_element?(view, "[data-testid='destructive-confirm']")
      assert has_element?(view, "[data-testid='admin-people-state-#{pending.id}']", "Pending")
      assert {:ok, :pending} = Identity.resolve_invite_link(raw)

      # This time the destructive button: the link is dead on the row.
      view
      |> element("[data-testid='admin-people-withdraw-#{pending.id}']")
      |> render_click()

      view
      |> element("[data-testid='admin-people-withdraw-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-info", "Invite withdrawn")
      assert has_element?(view, "[data-testid='admin-people-state-#{pending.id}']", "Withdrawn")
      assert {:ok, :withdrawn} = Identity.resolve_invite_link(raw)
    end

    test "an acceptance racing the confirm panel turns the withdraw into an honest refresh", %{
      conn: conn,
      admin: admin
    } do
      {pending, raw} = pending_invite!(admin)
      {:ok, view, _html} = live(conn, "/admin/people")

      view
      |> element("[data-testid='admin-people-withdraw-#{pending.id}']")
      |> render_click()

      # The invitee accepts while the panel is open.
      assert {:ok, _user, _jwt} = Identity.accept_invitation(raw)

      view
      |> element("[data-testid='admin-people-withdraw-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-error", "changed before the withdraw landed")
      assert has_element?(view, "[data-testid='admin-people-state-#{pending.id}']", "Accepted")
      refute has_element?(view, "[data-testid='destructive-confirm']")
    end

    test "a reveal naming a row that changed before the click refuses and refreshes", %{
      conn: conn,
      admin: admin
    } do
      # The stale-DOM shape: the button was rendered for a pending row,
      # the acceptance committed before the click. A crafted frame is
      # the same shape server-side, so the event is driven directly.
      {pending, raw} = pending_invite!(admin)
      {:ok, view, _html} = live(conn, "/admin/people")
      assert {:ok, _user, _jwt} = Identity.accept_invitation(raw)

      render_click(view, "open-withdraw", %{"id" => pending.id})

      assert has_element?(view, "#flash-error", "That invitation changed")
      refute has_element?(view, "[data-testid='destructive-confirm']")
      assert has_element?(view, "[data-testid='admin-people-state-#{pending.id}']", "Accepted")
    end

    test "a reinvite at an unsendable address is refused without a refresh", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/people")

      render_click(view, "reinvite", %{"email" => "not-an-address"})

      assert has_element?(view, "#flash-error", "does not look like an email address")
    end

    test "a reinvite at an address that just went active is refused", %{
      conn: conn,
      admin: admin
    } do
      {pending, raw} = pending_invite!(admin)
      {:ok, view, _html} = live(conn, "/admin/people")

      # The invitee accepts while the stale row still offers Reinvite.
      assert {:ok, _user, _jwt} = Identity.accept_invitation(raw)

      render_click(view, "reinvite", %{"email" => to_string(pending.email)})

      assert has_element?(view, "#flash-error", "already active")
      assert has_element?(view, "[data-testid='admin-people-state-#{pending.id}']", "Accepted")
    end
  end

  describe "the gates" do
    test "anonymous bounces to /sign-in", %{bare_conn: conn} do
      conn = get(conn, "/admin/people")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "a signed-in non-admin gets a bare 403", %{bare_conn: conn} do
      user = SessionHelpers.user!()
      signed = SessionHelpers.sign_in(conn, user)
      conn = get(signed, "/admin/people")

      assert conn.status == 403
    end

    test "non-admin actors are Forbidden on every write path", %{admin: admin} do
      non_admin = SessionHelpers.user!()

      # The create arm: an unoccupied address rides the :invite create.
      assert {:error, %Ash.Error.Forbidden{}} =
               Identity.invite_user(non_admin, unique_address())

      {pending, _raw} = pending_invite!(admin)

      # The reissue arm: the address resolves its occupant, whose
      # :reinvite update rides the same non-admin actor.
      assert {:error, %Ash.Error.Forbidden{}} =
               Identity.invite_user(non_admin, to_string(pending.email))

      assert {:error, %Ash.Error.Forbidden{}} = Identity.withdraw_invite(non_admin, pending)
    end
  end

  defp users_with_email(address) do
    User
    |> Ash.Query.filter(email == ^address)
    |> Ash.read!(authorize?: false)
  end
end
