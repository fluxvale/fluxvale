defmodule FluxValeWeb.SignInControllerTest do
  @moduledoc """
  The native sign-in track (#219): both steps complete over plain HTML
  form POSTs — no WebSocket, no LiveView connection, no JavaScript. The
  connected LiveView flow has its own suite (`AuthLive.SignInTest`); the
  verify arm lives in `SessionController` and is pinned here and in
  `SessionControllerTest`.
  """

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.Identity
  alias FluxVale.Ops.AccessRule

  @email "native-sign-in-#{System.unique_integer()}@fluxvale.com"

  defp deliver_and_extract_code do
    assert_receive {:email, %Swoosh.Email{text_body: body}}, 1_000
    [code] = Regex.run(~r/code is (\d{6})\./, body, capture: :all_but_first)
    code
  end

  defp request_code(conn, email, params \\ %{}) do
    post(conn, ~p"/auth/sign-in", Map.merge(%{"email" => email}, params))
  end

  test "the full round-trip rides native POSTs only, no LiveView connection", %{conn: conn} do
    # Step 1: the email form's POST. build_conn's csrf bypass is the test
    # harness's, not the flow's — the forms carry real tokens (pinned
    # below).
    requested = request_code(conn, @email, %{"return_to" => "/feedback/some-post"})

    assert redirected_to(requested) == ~p"/sign-in/code?return_to=%2Ffeedback%2Fsome-post"
    assert Phoenix.Flash.get(requested.assigns.flash, :info) == "Code sent. Check your inbox."

    # Step 2's page: an ordinary GET of the code step — the LiveView's
    # static render, with no socket and no connected mount.
    code_page =
      requested
      |> recycle()
      |> get(~p"/sign-in/code?return_to=%2Ffeedback%2Fsome-post")

    html = html_response(code_page, 200)

    assert html =~ "code-form"
    assert html =~ "We sent a 6-digit code to"
    assert html =~ ~s(name="email" value="#{@email}")

    # Step 2's POST: the code itself is the proof — the form goes
    # straight to the session write, no token minted in between.
    code = deliver_and_extract_code()

    signed_in =
      code_page
      |> recycle()
      |> post(~p"/auth/session", %{
        "email" => @email,
        "code" => code,
        "return_to" => "/feedback/some-post"
      })

    assert redirected_to(signed_in) == "/feedback/some-post"

    # The session is real, and it belongs to the JIT-provisioned account.
    session = Plug.Conn.get_session(signed_in)
    assert %{id: user_id} = FluxValeWeb.UserAuth.resolve_user(session)
    assert {:ok, %{id: ^user_id}} = Identity.User.get_by_email(@email, authorize?: false)
  end

  test "both steps render native POST fallbacks (the no-JavaScript shape)", %{conn: conn} do
    email_page =
      conn
      |> get(~p"/sign-in")
      |> html_response(200)

    assert email_page =~ ~s(action="/auth/sign-in")
    assert email_page =~ ~s(method="post")
    assert email_page =~ "data-native-fallback"
    assert email_page =~ ~s(name="_csrf_token")

    requested = request_code(conn, @email)

    code_page =
      requested
      |> recycle()
      |> get(~p"/sign-in/code")
      |> html_response(200)

    assert code_page =~ ~s(action="/auth/session")
    assert code_page =~ ~s(method="post")
    assert code_page =~ "data-native-fallback"
    assert code_page =~ ~s(name="_csrf_token")
    # The native verify carries the address; the minted-token input only
    # exists on the connected hand-off.
    assert code_page =~ ~s(name="email" value="#{@email}")
    refute code_page =~ ~s(name="token")
  end

  test "a malformed address returns to the email step with the reason", %{conn: conn} do
    refused = request_code(conn, "not-an-email")

    assert redirected_to(refused) == ~p"/sign-in"
    assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ "look like an email address"
    refute_received {:email, %Swoosh.Email{}}
  end

  test "a failed request keeps the return path for the retry", %{conn: conn} do
    refused = request_code(conn, "not-an-email", %{"return_to" => "/feedback/some-post"})

    assert redirected_to(refused) == "/sign-in?return_to=%2Ffeedback%2Fsome-post"
  end

  test "the send throttle answers a native retry without a second mail", %{conn: conn} do
    requested = request_code(conn, @email)
    assert redirected_to(requested) == ~p"/sign-in/code"
    _code = deliver_and_extract_code()

    retried =
      requested
      |> recycle()
      |> request_code(@email)

    assert redirected_to(retried) == ~p"/sign-in"
    assert Phoenix.Flash.get(retried.assigns.flash, :error) =~ "wait a minute"
    refute_received {:email, %Swoosh.Email{}}
  end

  test "a non-scalar email param is answered as malformed, never a crash", %{conn: conn} do
    refused = post(conn, ~p"/auth/sign-in", %{"email" => %{"a" => "b"}})

    assert redirected_to(refused) == ~p"/sign-in"
    assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ "look like an email address"
    refute_received {:email, %Swoosh.Email{}}
  end

  # #26: the gate runs inside the operation, so the native door is
  # exactly as closed as the LiveView one. The rule names its own
  # domain so this suite never waits on another suite's uncommitted
  # `(purpose, "fluxvale.com")` row (the unique index serializes them).
  test "a denied address is told to ask an admin", %{conn: conn} do
    allowed = "native-allowed-#{System.unique_integer()}.example"
    AccessRule.create!(%{domain: allowed}, authorize?: false)

    refused = request_code(conn, "outsider-#{System.unique_integer()}@example.com")

    assert redirected_to(refused) == ~p"/sign-in"
    assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ "Ask an admin for access"
    refute_received {:email, %Swoosh.Email{}}
  end

  test "an external return_to never rides the code page", %{conn: conn} do
    requested = request_code(conn, @email, %{"return_to" => "//evil.com"})

    assert redirected_to(requested) == ~p"/sign-in/code"
  end

  test "a direct code-page hit with no pending request returns to the email step", %{conn: conn} do
    page = get(conn, ~p"/sign-in/code")

    assert redirected_to(page) == ~p"/sign-in"
  end

  test "that bounce keeps the return path for the retry", %{conn: conn} do
    page = get(conn, ~p"/sign-in/code?return_to=%2Ffeedback%2Fsome-post")

    assert redirected_to(page) == ~p"/sign-in?return_to=%2Ffeedback%2Fsome-post"
  end
end
