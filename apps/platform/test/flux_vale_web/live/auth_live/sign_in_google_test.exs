defmodule FluxValeWeb.AuthLive.SignInGoogleTest do
  @moduledoc """
  The Google door on the sign-in surface (#642): the button's render
  predicate (GoogleOIDC.arm_available?/0 — the ONE conjunction the
  controller's hops gate on) and plan §5's fallback pin — the
  email-code flow completes end-to-end with the Google arm on, off,
  and unconfigured.
  """

  use FluxValeWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias FluxVale.Identity
  alias FluxVale.Ops.FeatureFlag

  setup do
    # The flag read's failure arm needs a stubbed raise — FeatureFlags
    # is Mimic-copied per the test_helper precedent (Identity et al.)
    Mimic.copy(FluxVale.Ops.FeatureFlags)

    # Credentials present through app env (the issuer override's seam):
    # configured?/0 reads the predicate — no outbound call, no provider
    # needed for rendering. async: false — the env is VM-global (the
    # GoogleOIDCTest posture).
    original = Application.get_env(:flux_vale, :google_oidc)
    FeatureFlag.create!("google_sign_in", %{enabled: true}, authorize?: false)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:flux_vale, :google_oidc)
        value -> Application.put_env(:flux_vale, :google_oidc, value)
      end
    end)

    :ok
  end

  defp creds_configured do
    Application.put_env(:flux_vale, :google_oidc,
      client_id: "mock-id",
      client_secret: "mock-secret"
    )
  end

  defp creds_absent do
    Application.put_env(:flux_vale, :google_oidc, client_id: nil, client_secret: nil)
  end

  defp flag_off do
    row = FeatureFlag.by_key!("google_sign_in", authorize?: false, not_found_error?: false)
    Ash.update!(row, %{enabled: false}, authorize?: false)
  end

  defp deliver_and_extract_code do
    assert_receive {:email, %Swoosh.Email{text_body: body}}, 1_000
    [code] = Regex.run(~r/code is (\d{6})\./, body, capture: :all_but_first)
    code
  end

  # Plan §5's fallback pin: the email-code flow's full arc — request,
  # verify, the trigger-action session write — in whatever state the
  # Google arm is in. No state exists in which email codes work worse
  # than today.
  defp email_flow_completes(conn, email) do
    {:ok, view, _html} = live(conn, ~p"/sign-in")

    result =
      view
      |> form("#email-form", email: email)
      |> render_submit()

    assert result =~ "code-form"

    code = deliver_and_extract_code()

    code_form = form(view, "#code-form", code: code)
    render_submit(code_form)

    conn = follow_trigger_action(code_form, conn)
    assert redirected_to(conn) == ~p"/"
    assert {:ok, _user} = Identity.User.get_by_email(email, authorize?: false)
  end

  describe "the button's render predicate (D-flag)" do
    test "renders on the email step when flag AND creds are on", %{conn: conn} do
      creds_configured()

      {:ok, view, _html} = live(conn, ~p"/sign-in")

      assert has_element?(view, ~s(a[data-testid="google-sign-in"]))
      assert has_element?(view, ~s([data-testid="google-divider"]), "or")
    end

    test "carries the validated return_to on its href", %{conn: conn} do
      creds_configured()

      {:ok, view, _html} = live(conn, ~p"/sign-in?return_to=/feedback/some-post")

      assert has_element?(
               view,
               ~s(a[data-testid="google-sign-in"][href="/auth/google?return_to=%2Ffeedback%2Fsome-post"])
             )

      # …and stays plain without one
      {:ok, plain, _html} = live(conn, ~p"/sign-in")
      assert has_element?(plain, ~s(a[data-testid="google-sign-in"][href="/auth/google"]))
    end

    test "hidden when the flag is off (creds on)", %{conn: conn} do
      creds_configured()
      flag_off()

      {:ok, view, _html} = live(conn, ~p"/sign-in")

      refute has_element?(view, ~s(a[data-testid="google-sign-in"]))
    end

    test "hidden when creds are absent (flag on)", %{conn: conn} do
      creds_absent()

      {:ok, view, _html} = live(conn, ~p"/sign-in")

      refute has_element?(view, ~s(a[data-testid="google-sign-in"]))
    end

    # The flag read rides the DB: a blip must not 500 a page that was
    # static before this arm existed — fail CLOSED (button hides), the
    # email door untouched (plan §5's no-worse guarantee).
    test "a failing flag read hides the button, never the page", %{conn: conn} do
      creds_configured()

      stub(FluxVale.Ops.FeatureFlags, :enabled?, fn _key -> raise "flag read failed" end)

      {:ok, view, _html} = live(conn, ~p"/sign-in")

      refute has_element?(view, ~s(a[data-testid="google-sign-in"]))
      assert has_element?(view, "#email-form")
      assert has_element?(view, "h1", "Sign in to FluxVale")
    end

    test "absent on the code step — the visitor is mid-flow", %{conn: conn} do
      creds_configured()
      email = "google-lv-#{System.unique_integer()}@fluxvale.com"

      {:ok, view, _html} = live(conn, ~p"/sign-in")

      view
      |> form("#email-form", email: email)
      |> render_submit()

      _code = deliver_and_extract_code()

      refute has_element?(view, ~s(a[data-testid="google-sign-in"]))
      assert has_element?(view, "#code-form")
    end
  end

  describe "plan §5's fallback pin — email codes work in every arm state" do
    test "arm ON: the email flow still completes end-to-end", %{conn: conn} do
      creds_configured()
      email_flow_completes(conn, "fallback-on-#{System.unique_integer()}@fluxvale.com")
    end

    test "arm OFF (flag row disabled): the email flow still completes", %{conn: conn} do
      creds_configured()
      flag_off()
      email_flow_completes(conn, "fallback-off-#{System.unique_integer()}@fluxvale.com")
    end

    test "arm UNCONFIGURED: the email flow still completes", %{conn: conn} do
      creds_absent()
      email_flow_completes(conn, "fallback-unconfigured-#{System.unique_integer()}@fluxvale.com")
    end
  end
end
