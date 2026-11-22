defmodule FluxValeWeb.OnboardingLiveTest do
  @moduledoc """
  The `/onboarding` flow (#831): the step machine renders in order,
  accepting the derived handle advances with no `:set_username` side
  effect, an edit renames through it (conflict copy included), every
  Skip and the final Finish stamp `:finish_onboarding` and land `/`,
  the agent step opens the #817 modal with the org-named prompt (and no
  dismissal card — that is `/agent`'s), a stamped account is bounced at
  mount, and (#887) a signal-complete account — live machine credential
  plus first instance, no stamp — converges the stamp and bounces the
  same way, never rendering the flow.
  """

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FluxVale.TestSupport.AccountsFixtures

  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  setup %{conn: conn} do
    user = user!()
    conn = SessionHelpers.sign_in(conn, user)
    %{user: user, conn: conn}
  end

  defp reload(user), do: Ash.get!(User, user.id, authorize?: false)

  test "the flow walks username → agent → walkthrough", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/onboarding")

    assert has_element?(view, "[data-testid='onboarding-step-username']")
    # the derived handle is the pre-filled suggestion
    assert render(element(view, "[data-testid='onboarding-username-input']")) =~
             user.username

    # accept-as-is: submitting the form with its pre-filled value advances
    view
    |> form("#onboarding-username-form")
    |> render_submit()

    assert has_element?(view, "[data-testid='onboarding-step-agent']")
    assert has_element?(view, "[data-testid='onboarding-agent-show-prompt']")
    assert has_element?(view, "[data-testid='onboarding-agent-open-page']")

    view
    |> element("[data-testid='onboarding-agent-continue']")
    |> render_click()

    assert has_element?(view, "[data-testid='onboarding-step-walkthrough']")

    assert has_element?(
             view,
             "[data-testid='onboarding-step-walkthrough']",
             "Pick from the catalog"
           )

    assert has_element?(
             view,
             "[data-testid='onboarding-step-walkthrough']",
             "Deploy to your box"
           )

    assert has_element?(
             view,
             "[data-testid='onboarding-step-walkthrough']",
             "Manage the instance"
           )

    assert has_element?(view, "[data-testid='onboarding-walkthrough-finish']")
  end

  test "accepting the derived handle advances with no :set_username side effect", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/onboarding")

    view
    |> form("#onboarding-username-form")
    |> render_submit()

    assert has_element?(view, "[data-testid='onboarding-step-agent']")

    # the handle is unchanged AND no write happened at all — the action
    # never ran (any update, stamp included, would move updated_at)
    reloaded = reload(user)
    assert reloaded.username == user.username
    assert reloaded.updated_at == user.updated_at
  end

  test "an edited handle renames through :set_username and advances", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/onboarding")

    view
    |> form("#onboarding-username-form", user: %{username: "terence"})
    |> render_submit()

    assert has_element?(view, "[data-testid='onboarding-step-agent']")
    assert reload(user).username == "terence"
  end

  test "a malformed handle surfaces ValidUsername's copy and holds the step", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/onboarding")

    view
    |> form("#onboarding-username-form", user: %{username: "Bad Handle!"})
    |> render_submit()

    assert has_element?(view, "[data-testid='onboarding-step-username']")
    assert has_element?(view, "#onboarding-username-form", "must use only lowercase letters")
  end

  test "a live edit surfaces ValidUsername's copy and holds the step", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/onboarding")

    view
    |> form("#onboarding-username-form", user: %{username: "Bad Handle!"})
    |> render_change()

    assert has_element?(view, "[data-testid='onboarding-step-username']")
    assert has_element?(view, "#onboarding-username-form", "must use only lowercase letters")
  end

  test "a taken handle renders the settings conflict copy and holds the step", %{conn: conn} do
    # the collision is action-produced: user!/1 pins the derived handle
    user!("taken-handle")

    {:ok, view, _html} = live(conn, ~p"/onboarding")

    view
    |> form("#onboarding-username-form", user: %{username: "taken-handle"})
    |> render_submit()

    assert has_element?(view, "[data-testid='onboarding-step-username']")
    assert has_element?(view, "#onboarding-username-form", "has already been taken")
  end

  test "Skip at the username step stamps and lands /", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/onboarding")

    view
    |> element("[data-testid='onboarding-skip']")
    |> render_click()

    assert_redirect(view, ~p"/")
    assert %DateTime{} = reload(user).onboarded_at
  end

  test "Skip at the agent step stamps and lands /", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/onboarding")

    view
    |> form("#onboarding-username-form")
    |> render_submit()

    view
    |> element("[data-testid='onboarding-skip']")
    |> render_click()

    assert_redirect(view, ~p"/")
    assert %DateTime{} = reload(user).onboarded_at
  end

  test "Skip at the walkthrough stamps and lands /", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/onboarding")

    view
    |> form("#onboarding-username-form")
    |> render_submit()

    view
    |> element("[data-testid='onboarding-agent-continue']")
    |> render_click()

    view
    |> element("[data-testid='onboarding-skip']")
    |> render_click()

    assert_redirect(view, ~p"/")
    assert %DateTime{} = reload(user).onboarded_at
  end

  test "Finish at the end stamps and lands /", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/onboarding")

    view
    |> form("#onboarding-username-form")
    |> render_submit()

    view
    |> element("[data-testid='onboarding-agent-continue']")
    |> render_click()

    view
    |> element("[data-testid='onboarding-walkthrough-finish']")
    |> render_click()

    assert_redirect(view, ~p"/")
    assert %DateTime{} = reload(user).onboarded_at
  end

  test "a stamped account direct-hitting /onboarding is bounced to /", %{conn: conn, user: user} do
    SessionHelpers.onboarded!(user)

    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/onboarding")
  end

  # #887: the agent-first-run shape — no stamp, but the signals landed
  # (a live machine credential + a first instance). Mount converges the
  # stamp and bounces; the flow never renders, and the next visit to /
  # agrees through the stamp alone.
  test "a signal-complete account direct-hitting /onboarding converges and bounces (#887)", %{
    conn: conn,
    user: user
  } do
    ApiPat.mint!(user, [])
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()
    InstanceFixtures.instance!(version, user)

    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/onboarding")
    assert %DateTime{} = reload(user).onboarded_at
  end

  test "a crafted continue frame on the last step is a no-op", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/onboarding")

    view
    |> form("#onboarding-username-form")
    |> render_submit()

    view
    |> element("[data-testid='onboarding-agent-continue']")
    |> render_click()

    # the machine has no next step past :walkthrough — the fence keeps
    # the socket where it is (the invite-accept posture)
    render_click(view, "continue-agent", %{})

    assert has_element?(view, "[data-testid='onboarding-step-walkthrough']")
  end

  test "the agent step opens the modal with the org-named prompt and no dismissal card", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/onboarding")

    view
    |> form("#onboarding-username-form")
    |> render_submit()

    view
    |> element("[data-testid='onboarding-agent-show-prompt']")
    |> render_click()

    # the #817 panel testids, inside the flow's own modal
    assert has_element?(view, "#onboarding-agent-modal [data-testid='agent-prompt']")
    assert has_element?(view, "#onboarding-agent-modal [data-testid='agent-clients']")
    assert has_element?(view, "#onboarding-agent-modal [data-testid='agent-what-it-will-do']")
    assert has_element?(view, "#onboarding-agent-modal [data-testid='agent-spend-rule']")

    # the prompt names THIS account's personal org
    org = personal_org!(user)
    assert has_element?(view, "#onboarding-agent-modal [data-testid='agent-prompt']", org.name)

    # the dismissal card is /agent's, never the flow's
    refute has_element?(view, "[data-testid='agent-dismiss']")

    # closing (the backdrop's cancel event) returns to the step intact
    view
    |> element("[data-testid='onboarding-agent-modal-backdrop']")
    |> render_click()

    refute has_element?(view, "#onboarding-agent-modal")
    assert has_element?(view, "[data-testid='onboarding-step-agent']")

    view
    |> element("[data-testid='onboarding-skip']")
    |> render_click()

    assert_redirect(view, ~p"/")
  end
end
