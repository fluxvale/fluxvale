defmodule FluxValeWeb.FeedbackLive.ComposerTest do
  @moduledoc """
  The composer at /feedback/new (#412 T5): the anonymous CTA, the
  working create happy path, the similar-posts nudge results, the
  picker's default, and the create gate's refusal rendering inline.
  """

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import FluxVale.TestSupport.FeedbackFixtures

  alias FluxVale.Billing
  alias FluxVale.Feedback.Post
  alias FluxVale.Ops.AccessRule
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures

  require Ash.Query

  # The composer is a full-page live route; a signed-in session rides
  # the same token the sign-in flow mints.
  defp mount_composer(conn, user \\ nil)

  defp mount_composer(conn, nil) do
    live(conn, ~p"/feedback/new")
  end

  defp mount_composer(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    live_isolated(conn, FluxValeWeb.FeedbackLive.Composer, session: %{"user_token" => token})
  end

  defp post_with_title_exists?(title) do
    Post
    |> Ash.Query.filter(title == ^title)
    |> Ash.exists?(authorize?: false)
  end

  # --- Route and anonymous ----------------------------------------------------------

  test "/feedback/new serves the composer live route, not the :slug capture", %{conn: conn} do
    {:ok, view, _html} = mount_composer(conn)

    assert view.module == FluxValeWeb.FeedbackLive.Composer
    assert has_element?(view, "article h1", "Post a request")
  end

  test "anonymous sees the sign-in CTA, never the form", %{conn: conn} do
    {:ok, view, _html} = mount_composer(conn)

    assert has_element?(view, "p", "Sign in to post a request.")
    assert has_element?(view, "a[data-testid='composer-sign-in'][href='/sign-in']", "Sign in")
    refute has_element?(view, "#composer-form")
  end

  test "a crafted anonymous submit is silence", %{conn: conn} do
    {:ok, view, _html} = mount_composer(conn)

    render_submit(view, "create", %{
      "post" => %{"title" => "A perfectly valid request title", "description" => "Body"}
    })

    refute post_with_title_exists?("A perfectly valid request title")
  end

  # The anonymous composer renders NO form (the sign-in CTA stands in),
  # so a crafted validate must be silence — a nil dereference would kill
  # the island a visitor lands on from the board's CTA.
  test "a crafted anonymous validate is silence (no form to validate)", %{conn: conn} do
    {:ok, view, _html} = mount_composer(conn)

    render_change(view, "validate", %{"post" => %{"title" => "typed anyway"}})

    assert Process.alive?(view.pid)
    assert has_element?(view, "p", "Sign in to post a request.")
  end

  # The rendered chip always carries phx-value-org-id; a crafted click
  # without one must not crash the picker.
  test "a crafted pick-org with no org-id is silence", %{conn: conn} do
    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)

    {:ok, view, _html} = mount_composer(conn, user)

    render_click(view, "pick-org")

    assert Process.alive?(view.pid)
    assert has_element?(view, "[data-testid='composer-submit']")
  end

  # --- The happy path ----------------------------------------------------------------

  test "an eligible actor posts and lands on the new post's page", %{conn: conn} do
    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)

    {:ok, view, _html} = mount_composer(conn, user)

    # The picker defaults to the personal org, named on the chip.
    assert has_element?(view, "#composer-org-picker button[aria-pressed='true']", user.username)

    view
    |> element("#composer-form")
    |> render_submit(%{
      "post" => %{"title" => "A brand new feature request", "description" => "Please build it"}
    })

    created =
      Post
      |> Ash.Query.filter(slug == "a-brand-new-feature-request")
      |> Ash.read_one!(authorize?: false)

    assert created.status == :open
    assert_redirect(view, "/feedback/#{created.slug}")
  end

  test "a short title is refused inline before any write", %{conn: conn} do
    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)

    {:ok, view, _html} = mount_composer(conn, user)

    view
    |> element("#composer-form")
    |> render_submit(%{"post" => %{"title" => "ab", "description" => "Body"}})

    refute post_with_title_exists?("ab")
    # The inline field error carries the domain's bound.
    assert has_element?(view, "#composer-form p", "4")
  end

  # --- The similar-posts nudge --------------------------------------------------------

  test "typing a title surfaces matching posts with their vote counts", %{conn: conn} do
    existing = post!(%{title: "Add dark mode toggle for settings"})
    set_counters!(existing, 5, 0)

    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)

    {:ok, view, _html} = mount_composer(conn, user)

    refute has_element?(view, "[data-testid='similar-posts']")

    render_change(view, "validate", %{
      "post" => %{"title" => "dark mode settings page", "description" => ""}
    })

    assert has_element?(view, "[data-testid='similar-posts']", "Already posted?")

    assert has_element?(
             view,
             "[data-testid='similar-post-#{existing.slug}']",
             "Add dark mode toggle for settings"
           )

    assert has_element?(view, "[data-testid='similar-post-#{existing.slug}']", "5 votes")

    # A title with no match clears the nudge.
    render_change(view, "validate", %{
      "post" => %{"title" => "totally unrelated keyboard widget", "description" => ""}
    })

    refute has_element?(view, "[data-testid='similar-posts']")
  end

  test "description keystrokes with an unchanged title reuse the last search", %{conn: conn} do
    existing = post!(%{title: "Add dark mode toggle for settings"})
    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)

    {:ok, view, _html} = mount_composer(conn, user)

    render_change(view, "validate", %{
      "post" => %{"title" => "dark mode settings page", "description" => ""}
    })

    assert has_element?(view, "[data-testid='similar-posts']")

    # The description changes; the title (and so the nudge) stays.
    render_change(view, "validate", %{
      "post" => %{"title" => "dark mode settings page", "description" => "Details here"}
    })

    assert has_element?(
             view,
             "[data-testid='similar-post-#{existing.slug}']",
             "Add dark mode toggle for settings"
           )
  end

  test "a crafted non-binary title is silence, not a crash", %{conn: conn} do
    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)

    {:ok, view, _html} = mount_composer(conn, user)

    render_change(view, "validate", %{
      "post" => %{"title" => %{"deep" => "map"}, "description" => ""}
    })

    refute has_element?(view, "[data-testid='similar-posts']")
  end

  test "a crafted validate payload without the post key is silence", %{conn: conn} do
    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)

    {:ok, view, _html} = mount_composer(conn, user)

    render_change(view, "validate", %{})

    assert has_element?(view, "#composer-form")
  end

  test "a crafted create payload without the post key is silence", %{conn: conn} do
    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)

    {:ok, view, _html} = mount_composer(conn, user)

    render_submit(view, "create", %{})

    refute post_with_title_exists?("A perfectly valid request title")
  end

  # --- The picker -----------------------------------------------------------------------

  test "a multi-org owner switches the posting org with the picker", %{conn: conn} do
    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)
    team = AccountsFixtures.owned_org!(user)
    {:ok, wallet} = Billing.ensure_wallet(team)
    BillingFixtures.mark_paid!(wallet)

    {:ok, view, _html} = mount_composer(conn, user)

    # Default: the personal org, selected.
    assert has_element?(view, "#composer-org-picker button[aria-pressed='true']", user.username)

    render_click(view, "pick-org", %{"org-id" => team.id})

    assert has_element?(view, "#composer-org-picker button[aria-pressed='true']", team.name)
    assert has_element?(view, "#composer-org-picker button[aria-pressed='false']", user.username)

    # The selected org rides the write: posting names the team org.
    view
    |> element("#composer-form")
    |> render_submit(%{
      "post" => %{"title" => "A team org posted request", "description" => "Body"}
    })

    created =
      Post
      |> Ash.Query.filter(slug == "a-team-org-posted-request")
      |> Ash.read_one!(authorize?: false)

    assert created.organization_id == team.id
  end

  test "a crafted unknown org id is silence", %{conn: conn} do
    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)

    {:ok, view, _html} = mount_composer(conn, user)

    render_click(view, "pick-org", %{"org-id" => Ash.UUID.generate()})

    # Still the personal org, still allowed.
    assert has_element?(view, "[data-testid='composer-submit']")
    refute has_element?(view, "[data-testid='composer-gate-copy']")
  end

  # --- The gate -----------------------------------------------------------------------

  test "a welcome-credit-only actor sees the honest gate copy with a top-up link", %{conn: conn} do
    user = AccountsFixtures.user!()

    {:ok, view, _html} = mount_composer(conn, user)

    assert has_element?(view, "[data-testid='composer-gate-copy']", "Posting needs a paid org.")
    assert has_element?(view, "[data-testid='composer-topup']", "Top up #{user.username} to post")
    assert has_element?(view, "a[data-testid='composer-topup'][href='/billing/topup']")
    # The affordance is gone: no submit button, the fields stay visible.
    refute has_element?(view, "[data-testid='composer-submit']")
    assert has_element?(view, "[data-testid='composer-title']")
  end

  test "a launch-allowlisted actor gets the working form", %{conn: conn} do
    user = AccountsFixtures.user!()
    AccessRule.create!(%{purpose: :feedback, email: user.email}, authorize?: false)

    {:ok, view, _html} = mount_composer(conn, user)

    assert has_element?(view, "[data-testid='composer-submit']")
    refute has_element?(view, "[data-testid='composer-gate-copy']")
  end

  test "a tampered submit under the gate is refused inline, nothing written", %{conn: conn} do
    user = AccountsFixtures.user!()

    {:ok, view, _html} = mount_composer(conn, user)

    view
    |> element("#composer-form")
    |> render_submit(%{
      "post" => %{"title" => "A perfectly valid request title", "description" => "Body"}
    })

    assert has_element?(view, "[data-testid='composer-error']", "Posting needs a paid org.")
    refute post_with_title_exists?("A perfectly valid request title")
  end

  # The policy refusal is an expected path, so it must not log the
  # unhandled-error stack AshPhoenix prints by default (the reason the
  # form sets warn_on_unhandled_errors?: false). Asserting the absence
  # is what makes that one-line option verifiable: delete it and this
  # test fails.
  test "a gate-refused submit logs no unhandled-error warning", %{conn: conn} do
    user = AccountsFixtures.user!()

    {:ok, view, _html} = mount_composer(conn, user)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        view
        |> element("#composer-form")
        |> render_submit(%{
          "post" => %{"title" => "A perfectly valid request title", "description" => "Body"}
        })
      end)

    refute log =~ "Unhandled error in form submission"
    assert has_element?(view, "[data-testid='composer-error']", "Posting needs a paid org.")
  end

  # The wire's shape is not a promise: a non-map value under the form
  # key must fall to the catch-all, not raise on Map.merge/2.
  test "a crafted non-map payload is silence in both handlers", %{conn: conn} do
    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)

    {:ok, view, _html} = mount_composer(conn, user)

    render_change(view, "validate", %{"post" => "not a map"})
    render_submit(view, "create", %{"post" => "not a map"})

    assert Process.alive?(view.pid)
    assert has_element?(view, "#composer-form")
  end
end
