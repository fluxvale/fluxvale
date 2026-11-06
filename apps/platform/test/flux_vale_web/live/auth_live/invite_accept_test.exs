defmodule FluxValeWeb.AuthLive.InviteAcceptTest do
  @moduledoc """
  The invitee's accept landing (#502, `/invites/accept`): the token
  resolves to exactly one rendered state — the open invite shows the
  Accept button (no PII), terminal states get their sentence, and the
  accept rides the one-shot native form POST (the JWT in the body,
  SessionController lands the invitee signed in).
  """

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveViewTest

  import FluxVale.TestSupport.UserInviteHelpers

  alias FluxVale.Identity
  alias FluxValeWeb.UserAuth

  setup do
    %{address: "accept-lv-#{System.unique_integer()}@partner.example"}
  end

  describe "the pending row" do
    test "renders the accept button, the sign-in note, and no PII", %{
      conn: conn,
      address: address
    } do
      {invited, raw} = invite_user!(address)

      {:ok, view, _html} = live(conn, "/invites/accept?token=#{raw}")

      assert has_element?(view, "h1", "You're invited")
      assert has_element?(view, "[data-testid='invite-accept']", "Accept and sign in")

      assert has_element?(
               view,
               "[data-testid='invite-accept-note']",
               "Accepting signs you in straight away."
             )

      # the state word is the whole answer — the invited address never renders
      refute render(view) =~ to_string(invited.email)

      # the session POST waits for the click — not triggered at mount
      assert has_element?(view, "#session-form")
      refute has_element?(view, "#session-form[phx-trigger-action]")
    end
  end

  describe "the accept click" do
    test "the one-shot POST carries the JWT and lands the invitee signed in", %{
      conn: conn,
      address: address
    } do
      {invited, raw} = invite_user!(address)

      {:ok, view, _html} = live(conn, "/invites/accept?token=#{raw}")

      view
      |> element("[data-testid='invite-accept']")
      |> render_click()

      # the minted JWT rides the hidden input, and the form is triggered
      assert has_element?(view, "#session-form[phx-trigger-action]")

      html = render(view)
      document = LazyHTML.from_fragment(html)
      token_input = LazyHTML.query(document, "#session-form input[name='token']")
      assert [jwt] = LazyHTML.attribute(token_input, "value")
      assert is_binary(jwt) and jwt != ""

      session_form = form(view, "#session-form")
      conn = follow_trigger_action(session_form, conn)

      # SessionController verified the JWT, stored the session, landed home
      assert redirected_to(conn) == ~p"/"
      session = Plug.Conn.get_session(conn)
      assert %{id: id} = UserAuth.resolve_user(session)
      assert id == invited.id
    end

    test "a not_allowed refusal flashes the sign-in door copy and holds the row", %{
      conn: conn,
      address: address
    } do
      {_invited, raw} = invite_user!(address)

      {:ok, view, _html} = live(conn, "/invites/accept?token=#{raw}")

      stub(Identity, :accept_invitation, fn _token -> {:error, :not_allowed} end)

      view
      |> element("[data-testid='invite-accept']")
      |> render_click()

      assert has_element?(view, "#flash-error", "Ask an admin for access")
      # the row did not move — the page stays on the accept button
      assert has_element?(view, "[data-testid='invite-accept']")
      refute has_element?(view, "#session-form[phx-trigger-action]")
    end

    test "a raced refusal re-resolves to the row's honest sentence", %{
      conn: conn,
      address: address
    } do
      {invited, raw} = invite_user!(address)

      {:ok, view, _html} = live(conn, "/invites/accept?token=#{raw}")

      # the window closed elsewhere between mount and click
      withdraw_invite!(invited)
      stub(Identity, :accept_invitation, fn _token -> {:error, :unavailable} end)

      view
      |> element("[data-testid='invite-accept']")
      |> render_click()

      assert has_element?(view, "#flash-error", "This invitation can no longer be accepted.")
      assert has_element?(view, "[data-testid='invite-state-copy']", "no longer open")
      refute has_element?(view, "[data-testid='invite-accept']")
    end

    test "any other refusal flashes and re-resolves once, without looping", %{
      conn: conn,
      address: address
    } do
      {_invited, raw} = invite_user!(address)

      {:ok, view, _html} = live(conn, "/invites/accept?token=#{raw}")

      # the row is untouched (the stub refuses), so the re-resolve reads
      # :pending again — one flash, one re-render, still the pending row
      stub(Identity, :accept_invitation, fn _token -> {:error, :already_accepted} end)

      view
      |> element("[data-testid='invite-accept']")
      |> render_click()

      assert has_element?(view, "#flash-error", "This invitation can no longer be accepted.")
      assert has_element?(view, "[data-testid='invite-accept']")
      refute has_element?(view, "#session-form[phx-trigger-action]")
    end
  end

  describe "the crafted-event fence" do
    test "an accept frame from a terminal state is a no-op", %{conn: conn, address: address} do
      {_invited, raw} = invite_user!(address)
      {:ok, _user, _token} = Identity.accept_invitation(raw)

      {:ok, view, _html} = live(conn, "/invites/accept?token=#{raw}")

      render_click(view, "accept", %{})

      assert has_element?(view, "[data-testid='invite-state-copy']", "already accepted")
    end
  end

  describe "the terminal rows" do
    test "accepted points back to sign-in", %{conn: conn, address: address} do
      {_invited, raw} = invite_user!(address)
      {:ok, _user, _token} = Identity.accept_invitation(raw)

      {:ok, view, _html} = live(conn, "/invites/accept?token=#{raw}")

      assert has_element?(view, "[data-testid='invite-state-copy']", "already accepted")
      assert has_element?(view, "[data-testid='invite-sign-in-link']")
      refute has_element?(view, "[data-testid='invite-accept']")
    end

    test "withdrawn carries the support pointer", %{conn: conn, address: address} do
      {invited, raw} = invite_user!(address)
      withdraw_invite!(invited)

      {:ok, view, _html} = live(conn, "/invites/accept?token=#{raw}")

      assert has_element?(view, "[data-testid='invite-state-copy']", "no longer open")
      assert render(view) =~ "support@fluxvale.com"
    end

    test "expired names the way back", %{conn: conn} do
      # actions cannot backdate the window — seed! is the sanctioned bypass
      expired_invited_user!("accept-lv-expired-#{System.unique_integer()}@partner.example")

      {:ok, view, _html} = live(conn, "/invites/accept?token=expired-raw")

      assert has_element?(view, "[data-testid='invite-state-copy']", "expired")
      assert render(view) =~ "Ask an admin to send a new one."
    end

    test "an unknown token says the link is not valid", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/invites/accept?token=not-a-real-token")

      assert has_element?(view, "[data-testid='invite-state-copy']", "not valid")
    end

    test "a missing token reads as an unknown link", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/invites/accept")

      assert has_element?(view, "[data-testid='invite-state-copy']", "not valid")
    end
  end
end
