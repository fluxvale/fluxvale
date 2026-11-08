defmodule FluxValeWeb.FeedbackLive.VoteIslandTest do
  @moduledoc """
  The post page's vote island (#412 T5): every island state — anonymous
  CTA, gate-refused paying copy, the working cast/retract with count
  changes, and the picker's defaults and per-org voted state. The gate
  predicate itself is under test in ActorOwnsPaidOrgTest; these tests
  drive the island's BRANCHING on it.
  """

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import FluxVale.TestSupport.FeedbackFixtures

  alias FluxVale.Feedback.Post
  alias FluxVale.Ops.AccessRule
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures

  defp mount_island(conn, post, user \\ nil) do
    session =
      if user do
        {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
        %{"user_token" => token, "slug" => post.slug}
      else
        %{"slug" => post.slug}
      end

    live_isolated(conn, FluxValeWeb.FeedbackLive.VoteIsland, session: session)
  end

  defp count!(post_id), do: Ash.get!(Post, post_id, authorize?: false).vote_count

  defp personal_org_id!(user) do
    {:ok, org} = FluxVale.Accounts.personal_org_for_user(user.id, authorize?: false)
    org.id
  end

  # --- Anonymous -----------------------------------------------------------------

  test "anonymous sees the count and a sign-in CTA, never a toggle", %{conn: conn} do
    post = post!()
    set_counters!(post, 4, 0)

    {:ok, view, _html} = mount_island(conn, post)

    assert has_element?(view, "[data-testid='vote-count']", "4 votes")
    assert has_element?(view, "[data-testid='vote-sign-in']", "Sign in to vote")
    # #462: the CTA carries the post page back through sign-in
    assert has_element?(
             view,
             "a[data-testid='vote-sign-in'][href='/sign-in?return_to=%2Ffeedback%2F#{post.slug}']"
           )

    refute has_element?(view, "[data-testid='vote-toggle']")
    refute has_element?(view, "[data-testid='vote-gate-copy']")
  end

  test "a crafted anonymous toggle is silence (the render never showed one)", %{conn: conn} do
    post = post!()

    {:ok, view, _html} = mount_island(conn, post)

    render_click(view, "toggle")

    assert count!(post.id) == 0
    refute has_element?(view, "[data-testid='vote-error']")
  end

  # --- Gate-refused ----------------------------------------------------------------

  test "a welcome-credit-only org gets the paying copy with the account top-up", %{conn: conn} do
    post = post!()
    user = AccountsFixtures.user!()

    {:ok, view, _html} = mount_island(conn, post, user)

    assert has_element?(view, "[data-testid='vote-gate-copy']", "Voting needs a paid org.")
    assert has_element?(view, "[data-testid='vote-topup']", "Top up #{user.username} to vote")

    assert has_element?(view, "a[data-testid='vote-topup'][href='/billing/topup']")
    refute has_element?(view, "[data-testid='vote-toggle']")
  end

  test "an org-less actor reads as anonymous (the auth chain refuses the sign-in)", %{conn: conn} do
    # Ash.Seed.seed! — the only org-less shape (the create action's JIT
    # change always provisions one; the documented exception). The
    # session chain resolves it to nil (no verified primary), so the
    # island shows the sign-in CTA, not paying copy.
    orgless =
      Ash.Seed.seed!(FluxVale.Identity.User, %{
        username: "orgless-vote-#{System.unique_integer()}"
      })

    post = post!()

    {:ok, view, _html} = mount_island(conn, post, orgless)

    assert has_element?(view, "[data-testid='vote-sign-in']")
    refute has_element?(view, "[data-testid='vote-gate-copy']")
    refute has_element?(view, "#vote-org-picker")
  end

  test "an unpaid team org gets its own top-up link", %{conn: conn} do
    post = post!()
    user = AccountsFixtures.user!()
    team = AccountsFixtures.owned_org!(user)

    {:ok, view, _html} = mount_island(conn, post, user)

    # Default is the personal org; switching to the unpaid team org
    # moves the top-up link with it.
    render_click(view, "pick-org", %{"org-id" => team.id})

    assert has_element?(
             view,
             "a[data-testid='vote-topup'][href='/organizations/#{team.slug}/billing/topup']"
           )
  end

  # --- Eligible ----------------------------------------------------------------------

  test "an eligible actor casts, the count moves, and the toggle flips", %{conn: conn} do
    post = post!()
    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)

    {:ok, view, _html} = mount_island(conn, post, user)

    assert has_element?(view, "#vote-toggle", "Vote as")
    assert has_element?(view, "#vote-toggle[aria-pressed='false']")
    # A single-org owner sees no picker.
    refute has_element?(view, "#vote-org-picker")

    render_click(view, "toggle")

    assert count!(post.id) == 1
    assert has_element?(view, "[data-testid='vote-count']", "1 vote")
    assert has_element?(view, "#vote-toggle[aria-pressed='true']")
    assert has_element?(view, "#vote-toggle", "Voted as")

    render_click(view, "toggle")

    assert count!(post.id) == 0
    assert has_element?(view, "[data-testid='vote-count']", "0 votes")
    assert has_element?(view, "#vote-toggle[aria-pressed='false']")
  end

  test "a launch-allowlisted actor passes through the island too", %{conn: conn} do
    post = post!()
    user = AccountsFixtures.user!()

    AccessRule.create!(%{purpose: :feedback, email: AccountsFixtures.primary_address!(user)},
      authorize?: false
    )

    {:ok, view, _html} = mount_island(conn, post, user)

    render_click(view, "toggle")

    assert count!(post.id) == 1
    assert has_element?(view, "#vote-toggle[aria-pressed='true']")
  end

  # --- The picker -----------------------------------------------------------------------

  test "a multi-org owner gets the picker, personal org selected first", %{conn: conn} do
    post = post!()
    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)
    team = AccountsFixtures.owned_org!(user)

    {:ok, view, _html} = mount_island(conn, post, user)

    assert has_element?(view, "#vote-org-picker")
    assert has_element?(view, "#vote-org-picker button[aria-pressed='true']", user.username)
    assert has_element?(view, "#vote-org-picker button[aria-pressed='false']", team.name)
  end

  test "switching orgs reflects that org's voted state and its gate copy", %{conn: conn} do
    post = post!()
    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)
    team = AccountsFixtures.owned_org!(user)

    {:ok, view, _html} = mount_island(conn, post, user)

    render_click(view, "toggle")
    assert count!(post.id) == 1

    render_click(view, "pick-org", %{"org-id" => team.id})

    # The unpaid team org: not voted and the paying copy for IT.
    assert has_element?(view, "[data-testid='vote-gate-copy']")
    refute has_element?(view, "#vote-toggle")

    render_click(view, "pick-org", %{"org-id" => personal_org_id!(user)})

    # Back on the paid personal org: still voted.
    assert has_element?(view, "#vote-toggle[aria-pressed='true']")
  end

  test "a crafted unknown org id is silence", %{conn: conn} do
    post = post!()
    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)

    {:ok, view, _html} = mount_island(conn, post, user)

    render_click(view, "pick-org", %{"org-id" => Ash.UUID.generate()})

    # Still the personal org, still allowed.
    assert has_element?(view, "#vote-toggle")
    refute has_element?(view, "[data-testid='vote-gate-copy']")
  end

  # The rendered chip always carries phx-value-org-id; a crafted click
  # without one must fall to the catch-all, not a FunctionClauseError.
  test "a crafted pick-org with no org-id is silence", %{conn: conn} do
    post = post!()
    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)

    {:ok, view, _html} = mount_island(conn, post, user)

    render_click(view, "pick-org")

    assert Process.alive?(view.pid)
    assert has_element?(view, "#vote-toggle")
    refute has_element?(view, "[data-testid='vote-gate-copy']")
  end

  # --- Inline errors -------------------------------------------------------------------------

  test "a stale cast (another tab voted first) renders the error inline, count unchanged", %{
    conn: conn
  } do
    post = post!()
    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)

    {:ok, view_a, _html} = mount_island(conn, post, user)
    {:ok, view_b, _html} = mount_island(conn, post, user)

    render_click(view_a, "toggle")
    assert count!(post.id) == 1

    # B still shows not-voted; its cast hits the one-per-org identity.
    render_click(view_b, "toggle")

    assert has_element?(view_b, "[data-testid='vote-error']", "didn't go through")
    assert count!(post.id) == 1
    # A's state never moved.
    refute has_element?(view_a, "[data-testid='vote-error']")
  end

  test "a stale retract (another tab retracted first) renders the error inline", %{conn: conn} do
    post = post!()
    user = AccountsFixtures.user!()
    BillingFixtures.mark_user_paid!(user)

    # A casts first, so B mounts seeing the org as voted.
    {:ok, view_a, _html} = mount_island(conn, post, user)
    render_click(view_a, "toggle")
    {:ok, view_b, _html} = mount_island(conn, post, user)
    assert has_element?(view_b, "#vote-toggle[aria-pressed='true']")

    # A retracts the row away; B's retract hits the already-gone row.
    render_click(view_a, "toggle")
    assert count!(post.id) == 0

    render_click(view_b, "toggle")

    assert has_element?(view_b, "[data-testid='vote-error']", "didn't go through")
    assert count!(post.id) == 0
  end

  # --- A missing post ----------------------------------------------------------------------------

  test "a missing post renders the island empty (deleted mid-session)", %{conn: conn} do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(AccountsFixtures.user!())

    {:ok, view, html} =
      live_isolated(conn, FluxValeWeb.FeedbackLive.VoteIsland,
        session: %{
          "user_token" => token,
          "slug" => "no-such-post"
        }
      )

    refute html =~ "data-testid='vote-island'"
    refute has_element?(view, "[data-testid='vote-island']")
  end

  test "crafted events on a missing post are silence (the affordance dies with the post)", %{
    conn: conn
  } do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(AccountsFixtures.user!())

    {:ok, view, _html} =
      live_isolated(conn, FluxValeWeb.FeedbackLive.VoteIsland,
        session: %{
          "user_token" => token,
          "slug" => "no-such-post"
        }
      )

    render_click(view, "toggle")
    render_click(view, "pick-org", %{"org-id" => Ash.UUID.generate()})
    # A crafted click with no org-id at all: the handler's catch-all,
    # not a FunctionClauseError that would kill the channel.
    render_click(view, "pick-org")

    # The channel survived every crafted event (a crash would have taken
    # the process with it) and still renders empty.
    assert Process.alive?(view.pid)
    refute has_element?(view, "[data-testid='vote-island']")
  end
end
