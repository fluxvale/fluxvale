defmodule FluxValeWeb.AuthLive.SignInTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Identity

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
end
