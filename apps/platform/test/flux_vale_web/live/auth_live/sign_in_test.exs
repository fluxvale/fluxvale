defmodule FluxValeWeb.AuthLive.SignInTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveViewTest

  alias FluxVale.Identity
  alias FluxVale.Ops.AccessRule

  @email "lv-test-#{System.unique_integer()}@fluxvale.com"

  defp deliver_and_extract_code do
    assert_receive {:email, %Swoosh.Email{text_body: body}}, 1_000
    [code] = Regex.run(~r/code is (\d{6})\./, body, capture: :all_but_first)
    code
  end

  test "renders the email step", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sign-in")

    assert html =~ "Sign in to FluxVale"
    assert html =~ "email-form"
  end

  # Auth surfaces are noindex (the launch SEO audit gap): the mount's
  # robots_noindex assign is the same key the SeoNoindex plug sets on
  # non-canonical hosts, and the root layout's seo tags turn it into
  # the <meta name="robots">. The host IS the canonical one here, so
  # the plug is a no-op — the meta can only come from the mount.
  test "carries the robots noindex meta", %{conn: conn} do
    {:ok, _view, html} = live(%{conn | host: "fluxvale.com"}, ~p"/sign-in")

    assert html =~ ~s(name="robots" content="noindex, nofollow")
  end

  # #409: the sign-in surface rides the minimal auth layout — the mark
  # links home, the app chrome (header and nav) is gone, the flash
  # group stays. Both steps are states of this one LiveView, so the
  # frame is re-asserted on the code step too.
  test "renders the minimal auth layout on both steps", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sign-in")

    assert has_element?(view, ~s(a[aria-label="FluxVale"][href="/"]))
    assert has_element?(view, "#flash-group")
    refute has_element?(view, "header")
    refute has_element?(view, ~s(nav[aria-label="Primary"]))

    view
    |> form("#email-form", email: @email)
    |> render_submit()

    # The flash path rides the minimal layout's flash group
    assert has_element?(view, "#code-form")
    assert has_element?(view, "#flash-group", "Code sent")
    assert has_element?(view, ~s(a[aria-label="FluxVale"][href="/"]))
    refute has_element?(view, "header")
  end

  # The bypass acceptance through the UI: an @fluxvale.com address
  # creates an account with no extra step (#478).
  test "full flow: request, verify, session write via trigger-action POST", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/sign-in")

    result =
      view
      |> form("#email-form", email: @email)
      |> render_submit()

    assert result =~ "code-form"

    code = deliver_and_extract_code()

    code_form = form(view, "#code-form", code: code)
    render_submit(code_form)

    # The native form POST lands on SessionController, which stores the
    # framework-standard session and redirects home
    conn = follow_trigger_action(code_form, conn)
    assert redirected_to(conn) == ~p"/"

    # And the account exists (JIT)
    assert {:ok, _user} = Identity.User.get_by_email(@email, authorize?: false)
  end

  # #462: the return path's whole arc — link param in, POST body out,
  # session write lands the visitor back on the page they left.
  test "the return path rides the POST and lands back on the target", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/sign-in?return_to=/feedback/some-post")

    view
    |> form("#email-form", email: @email)
    |> render_submit()

    code = deliver_and_extract_code()

    # The validated value is in the verify form's body, ready for the POST
    assert has_element?(view, "input[name='return_to'][value='/feedback/some-post']")

    code_form = form(view, "#code-form", code: code)
    render_submit(code_form)

    conn = follow_trigger_action(code_form, conn)
    assert redirected_to(conn) == "/feedback/some-post"
  end

  test "an external return_to is dropped before the form renders it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/sign-in?return_to=//evil.com")

    view
    |> form("#email-form", email: @email)
    |> render_submit()

    code = deliver_and_extract_code()

    # Silent ignore: no hidden input, so the POST cannot carry it either
    refute has_element?(view, "input[name='return_to']")

    code_form = form(view, "#code-form", code: code)
    render_submit(code_form)

    conn = follow_trigger_action(code_form, conn)
    assert redirected_to(conn) == ~p"/"
  end

  test "wrong code shows a uniform error and stays on the code step", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/sign-in")
    email_form = form(view, "#email-form", email: @email)
    render_submit(email_form)
    _code = deliver_and_extract_code()

    result =
      view
      |> form("#code-form", code: "000000")
      |> render_submit()

    assert result =~ "That code didn&#39;t match"

    assert has_element?(view, "#code-form")
  end

  test "throttled resend surfaces a friendly error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sign-in")

    result =
      view
      |> form("#email-form", email: @email)
      |> render_submit()

    assert result =~ "code-form"

    code_form = form(view, "#code-form", code: "000000")
    render_submit(code_form)

    change_email = element(view, "button", "Use a different email")
    render_click(change_email)

    resend_result =
      view
      |> form("#email-form", email: @email)
      |> render_submit()

    assert resend_result =~ "wait a minute"
  end

  test "a malformed address is named, not mailed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sign-in")

    result =
      view
      |> form("#email-form", email: "not-an-email")
      |> render_submit()

    # NB: the apostrophe arrives HTML-escaped — assert on the stable tail
    assert result =~ "look like an email address"
    assert has_element?(view, "#email-form")
    refute result =~ "code-form"
    refute_received {:email, %Swoosh.Email{}}
  end

  # #26: the door itself — explicit message, not enumeration-safe (staging
  # is team-only; uniform messaging is a beta-invite-flow concern)
  test "a denied address is told to ask an admin — and stays on the email step", %{
    conn: conn
  } do
    AccessRule.create!(%{domain: "fluxvale.com"}, authorize?: false)

    {:ok, view, _html} = live(conn, ~p"/sign-in")

    result =
      view
      |> form("#email-form", email: "outsider-#{System.unique_integer()}@example.com")
      |> render_submit()

    assert result =~ "Ask an admin for access"
    assert result =~ "email-form"
    refute result =~ "code-form"
    refute_received {:email, %Swoosh.Email{}}
  end

  # #26: the rule changed between code-send and verify — that code can
  # never succeed; bounce to the email step with the why, not the generic
  # wrong-code message (the mint gate's UX half)
  test "a rule landing mid-flow bounces verify back to the email step", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/sign-in")

    view
    |> form("#email-form", email: @email)
    |> render_submit()

    code = deliver_and_extract_code()

    # …the door closes to exact-address rows before the code is used
    AccessRule.create!(%{email: "one@fluxvale.com"}, authorize?: false)

    result =
      view
      |> form("#code-form", code: code)
      |> render_submit()

    assert result =~ "Ask an admin for access"
    assert result =~ "email-form"
    refute result =~ "code-form"
  end

  test "delivery failure flashes a retry message, not a stack trace", %{conn: conn} do
    stub(Identity, :request_auth_code, fn _email -> {:error, :delivery_failed} end)

    {:ok, view, _html} = live(conn, ~p"/sign-in")

    html =
      view
      |> form("#email-form", email: @email)
      |> render_submit()

    # NB: apostrophe arrives HTML-escaped — assert on the stable tail
    assert html =~ "send the email"
    assert html =~ "Please wait a minute, then try again."
  end

  test "lockout on verify resets to the email step with the why", %{conn: conn} do
    stub(Identity, :verify_auth_code, fn _email, _code -> {:error, :locked_out} end)

    {:ok, view, _html} = live(conn, ~p"/sign-in")

    result =
      view
      |> form("#email-form", email: @email)
      |> render_submit()

    assert result =~ "code-form"

    html =
      view
      |> form("#code-form", code: "123456")
      |> render_submit()

    assert html =~ "Too many attempts. Request a fresh code."
    assert html =~ "email-form"
  end

  # #502: the email step carries the honest hint — accounts are created
  # by an admin's invitation, and the emailed link is the door
  test "the email step carries the honest invitation hint", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sign-in")

    assert render(view) =~ "New accounts start with an invitation"
  end

  # #502: the invited account's only door is the accept link — a code
  # verify against it bounces to the email step with the why (the
  # :invitation_required shape)
  test "an invited address is pointed at its accept link, draft intact", %{
    conn: conn
  } do
    stub(Identity, :verify_auth_code, fn _email, _code -> {:error, :invite_pending} end)

    {:ok, view, _html} = live(conn, ~p"/sign-in")

    view
    |> form("#email-form", email: @email)
    |> render_submit()

    result =
      view
      |> form("#code-form", code: "123456")
      |> render_submit()

    assert result =~ "invitation waiting"
    assert result =~ "Use the link in the invitation email"
    # back at the email step, their email draft intact
    assert has_element?(view, "#email-form")
    assert has_element?(view, "input[name='email'][value='#{@email}']")
    refute has_element?(view, "#code-form")
  end

  test "a non-invited external address is refused with the honest copy at the wall", %{
    conn: conn
  } do
    outsider = "wall-#{System.unique_integer()}@partner.example"
    {:ok, view, _html} = live(conn, ~p"/sign-in")

    view
    |> form("#email-form", email: outsider)
    |> render_submit()

    code = deliver_and_extract_code()

    result =
      view
      |> form("#code-form", code: code)
      |> render_submit()

    assert result =~ "invitation-only early access"
    assert result =~ "support@fluxvale.com"
    # back at the email step, their email draft intact
    assert has_element?(view, "#email-form")
    assert has_element?(view, "input[name='email'][value='#{outsider}']")
    refute has_element?(view, "#code-form")

    # and no account exists behind the wall
    assert {:error, _not_found} = Identity.User.get_by_email(outsider, authorize?: false)
  end

  # #502: the code wall admits the team domain only — an invited user
  # never passes here (they take the accept link), but a team-domain
  # address still JIT-provisions through the UI.
  test "a team-domain address provisions through the UI", %{conn: conn} do
    invited = "ui-invited-#{System.unique_integer()}@fluxvale.com"

    {:ok, view, _html} = live(conn, ~p"/sign-in")

    view
    |> form("#email-form", email: invited)
    |> render_submit()

    code = deliver_and_extract_code()

    code_form = form(view, "#code-form", code: code)
    render_submit(code_form)

    conn = follow_trigger_action(code_form, conn)
    assert redirected_to(conn) == ~p"/"

    assert {:ok, _user} = Identity.User.get_by_email(invited, authorize?: false)
  end

  test "an existing account signs in through the UI untouched by the gate", %{conn: conn} do
    # the account predates the flow (operator-seed shape, an external
    # domain so the team bypass is not what admits it): the gate never
    # asks, the sign-in is as it was, and the session is THAT account
    external = "ui-existing-#{System.unique_integer()}@partner.example"
    existing = Identity.User.create!(external, %{}, authorize?: false)

    {:ok, view, _html} = live(conn, ~p"/sign-in")

    view
    |> form("#email-form", email: external)
    |> render_submit()

    code = deliver_and_extract_code()

    code_form = form(view, "#code-form", code: code)
    render_submit(code_form)

    conn = follow_trigger_action(code_form, conn)
    assert redirected_to(conn) == ~p"/"

    session = Plug.Conn.get_session(conn)
    assert %{id: id} = FluxValeWeb.UserAuth.resolve_user(session)
    assert id == existing.id
  end
end
