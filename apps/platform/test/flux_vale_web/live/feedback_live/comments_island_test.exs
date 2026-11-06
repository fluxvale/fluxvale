defmodule FluxValeWeb.FeedbackLive.CommentsIslandTest do
  @moduledoc """
  The post page's comments island (#412 T5): the anonymous CTA, the
  list's stream rendering with the author_username projection, and the
  authenticated form — create streaming into the list, bounds errors
  inline, and the count following.
  """

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import FluxVale.TestSupport.FeedbackFixtures

  alias FluxVale.Feedback.Comment
  alias FluxVale.Feedback.Post
  alias FluxVale.TestSupport.AccountsFixtures

  defp mount_island(conn, post, user \\ nil) do
    session =
      if user do
        {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
        %{"user_token" => token, "slug" => post.slug}
      else
        %{"slug" => post.slug}
      end

    live_isolated(conn, FluxValeWeb.FeedbackLive.CommentsIsland, session: session)
  end

  defp count!(post_id), do: Ash.get!(Post, post_id, authorize?: false).comment_count

  defp position(html, needle) do
    assert html =~ needle
    {pos, _len} = :binary.match(html, needle)
    pos
  end

  # Comments for pre-seeding the list — the create action with a real
  # author (the create policy admits any actor, the CommentTest posture).
  defp comment!(post, author, body) do
    comment = Comment.create!(%{post_id: post.id, body: body}, actor: author)
    Ash.load!(comment, :author_username)
  end

  # --- Anonymous -----------------------------------------------------------------

  test "anonymous reads the list and gets the sign-in CTA", %{conn: conn} do
    post = post!()
    author = AccountsFixtures.user!()
    comment!(post, author, "First comment from the floor")

    {:ok, view, _html} = mount_island(conn, post)

    assert has_element?(view, "[data-testid='comments-island']")
    assert has_element?(view, "#comments", "First comment from the floor")
    assert has_element?(view, "[data-testid='comment']", author.username)
    assert has_element?(view, "[data-testid='comment-sign-in']", "Sign in to comment")
    # #462: the CTA carries the post page back through sign-in
    assert has_element?(
             view,
             "a[data-testid='comment-sign-in'][href='/sign-in?return_to=%2Ffeedback%2F#{post.slug}']"
           )

    refute has_element?(view, "#comment-form")
  end

  test "a fresh post renders the empty state", %{conn: conn} do
    post = post!()

    {:ok, view, _html} = mount_island(conn, post)

    assert has_element?(view, "[data-testid='comments-island']", "No comments yet.")
    assert has_element?(view, "#comments-count", "0 comments")
  end

  test "the heading counts through ngettext", %{conn: conn} do
    post = post!()
    author = AccountsFixtures.user!()
    comment!(post, author, "Only one so far")

    {:ok, view, _html} = mount_island(conn, post)

    assert has_element?(view, "#comments-count", "1 comment")
  end

  # --- Authenticated -----------------------------------------------------------------

  test "a signed-in actor sees the form and posts into the stream", %{conn: conn} do
    post = post!()
    user = AccountsFixtures.user!()

    {:ok, view, _html} = mount_island(conn, post, user)

    assert has_element?(view, "#comment-form")
    refute has_element?(view, "[data-testid='comment-sign-in']")

    view
    |> element("#comment-form")
    |> render_submit(%{"comment" => %{"body" => "A fresh comment from the test"}})

    assert has_element?(view, "#comments", "A fresh comment from the test")
    # The counter moved with the write.
    assert count!(post.id) == 1
    assert has_element?(view, "#comments-count", "1 comment")
    # The form is blank again for the next comment.
    assert has_element?(view, "#comment-form")
  end

  test "a posted comment renders ABOVE the older ones (the list is newest first)", %{
    conn: conn
  } do
    post = post!()
    author = AccountsFixtures.user!()
    comment!(post, author, "The older comment")

    user = AccountsFixtures.user!()

    {:ok, view, _html} = mount_island(conn, post, user)

    view
    |> element("#comment-form")
    |> render_submit(%{"comment" => %{"body" => "The brand new comment"}})

    html = render(view)
    assert position(html, "The brand new comment") < position(html, "The older comment")
  end

  test "an empty body keeps the comment off the list with the error inline", %{conn: conn} do
    post = post!()
    user = AccountsFixtures.user!()

    {:ok, view, _html} = mount_island(conn, post, user)

    view
    |> element("#comment-form")
    |> render_submit(%{"comment" => %{"body" => ""}})

    assert has_element?(view, "#comments-count", "0 comments")
    assert count!(post.id) == 0
    # The required refusal renders under the field (the form's field error).
    assert has_element?(view, "#comment-form p", "is required")
  end

  test "an oversized body is refused inline at the server bound", %{conn: conn} do
    post = post!()
    user = AccountsFixtures.user!()

    {:ok, view, _html} = mount_island(conn, post, user)

    view
    |> element("#comment-form")
    |> render_submit(%{"comment" => %{"body" => String.duplicate("x", 5001)}})

    assert count!(post.id) == 0
    assert has_element?(view, "#comment-form p", "5000")
  end

  test "a crafted anonymous submit is silence (the policy is the gate)", %{conn: conn} do
    post = post!()

    {:ok, view, _html} = mount_island(conn, post)

    render_submit(view, "submit-comment", %{"comment" => %{"body" => "sneaky"}})

    assert count!(post.id) == 0
    assert has_element?(view, "[data-testid='comment-sign-in']")
  end

  # --- Post deleted mid-session --------------------------------------------------------------

  # The island outliving its post (deleted between the SSR render and
  # the connect) must stay silent under crafted events, not crash.
  test "crafted events on a missing post are silence", %{conn: conn} do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(AccountsFixtures.user!())

    {:ok, view, _html} =
      live_isolated(conn, FluxValeWeb.FeedbackLive.CommentsIsland,
        session: %{
          "user_token" => token,
          "slug" => "no-such-post"
        }
      )

    render_change(view, "validate", %{"comment" => %{"body" => "typed"}})
    render_submit(view, "submit-comment", %{"comment" => %{"body" => "posted"}})

    refute has_element?(view, "[data-testid='comments-island']")
  end

  # The anonymous island renders the sign-in CTA instead of a form, so a
  # crafted validate must be silence, not a nil dereference.
  test "a crafted anonymous validate is silence (no form to validate)", %{conn: conn} do
    post = post!()

    {:ok, view, _html} = mount_island(conn, post)

    render_change(view, "validate", %{"comment" => %{"body" => "typed anyway"}})

    assert Process.alive?(view.pid)
    assert has_element?(view, "[data-testid='comment-sign-in']")
  end

  # --- Keystroke validation --------------------------------------------------------------------

  test "typing shows the bounds error live, before any submit", %{conn: conn} do
    post = post!()
    user = AccountsFixtures.user!()

    {:ok, view, _html} = mount_island(conn, post, user)

    render_change(view, "validate", %{"comment" => %{"body" => String.duplicate("x", 5001)}})

    assert has_element?(view, "#comment-form p", "5000")
    assert count!(post.id) == 0

    # Clearing the body clears the error.
    render_change(view, "validate", %{"comment" => %{"body" => "now valid"}})

    refute has_element?(view, "#comment-form p", "5000")
  end

  test "a crafted validate payload without the comment key is silence", %{conn: conn} do
    post = post!()
    user = AccountsFixtures.user!()

    {:ok, view, _html} = mount_island(conn, post, user)

    render_change(view, "validate", %{})

    assert has_element?(view, "#comment-form")
    assert count!(post.id) == 0
  end

  # A non-map value under the form key falls to the catch-all, not a
  # Map.merge/2 raise.
  test "a crafted non-map payload is silence in both handlers", %{conn: conn} do
    post = post!()
    user = AccountsFixtures.user!()

    {:ok, view, _html} = mount_island(conn, post, user)

    render_change(view, "validate", %{"comment" => "not a map"})
    render_submit(view, "submit-comment", %{"comment" => "not a map"})

    assert Process.alive?(view.pid)
    assert has_element?(view, "#comment-form")
    assert count!(post.id) == 0
  end

  test "a crafted submit payload without the comment key is silence", %{conn: conn} do
    post = post!()
    user = AccountsFixtures.user!()

    {:ok, view, _html} = mount_island(conn, post, user)

    render_submit(view, "submit-comment", %{})

    assert count!(post.id) == 0
  end

  # --- Markdown bodies (#488) -----------------------------------------------------

  # The island renders bodies through FluxVale.Feedback.Markdown, the
  # same sanitized renderer the post page uses — computed in the
  # template so the SSR list and every stream insert agree.

  test "a markdown comment renders its markup", %{conn: conn} do
    post = post!()
    author = AccountsFixtures.user!()

    comment!(post, author, "This is **the fix** and a [link](https://example.com)")

    {:ok, view, _html} = mount_island(conn, post)

    html = render(view)

    assert html =~ "<strong>the fix</strong>"
    assert html =~ "<a href=\"https://example.com\" rel=\"noopener\">link</a>"
  end

  # The island-level hostile pin: fails if the renderer's sanitization
  # ever regresses.
  test "a hostile comment renders inert", %{conn: conn} do
    post = post!()
    author = AccountsFixtures.user!()

    comment!(
      post,
      author,
      "<script>alert(1)</script><img src=x onerror=alert(1)>[click](javascript:alert(1))[x](data:text/html;base64,PHNjcmlwdD4=)<div>raw</div>"
    )

    {:ok, view, _html} = mount_island(conn, post)

    html = render(view)

    refute html =~ "<script>alert"
    refute html =~ "onerror"
    refute html =~ "javascript:"
    refute html =~ "data:"
    refute html =~ "<div>raw</div>"
  end

  # A comment written before Markdown keeps its single newlines. The
  # break's exact serialization differs between the raw render (`<br>`)
  # and the island's streamed markup (`<br/>`) — the pin is the break.
  test "a legacy plain-text comment keeps its line breaks", %{conn: conn} do
    post = post!()
    author = AccountsFixtures.user!()

    comment!(post, author, "first line of an old comment\nsecond line after one newline")

    {:ok, view, _html} = mount_island(conn, post)

    assert render(view) =~ "first line of an old comment<br"
    assert render(view) =~ "\nsecond line after one newline</p>"
  end

  # The freshly posted comment streams in already rendered.
  test "a submitted markdown comment renders as markdown in the stream", %{conn: conn} do
    post = post!()
    user = AccountsFixtures.user!()

    {:ok, view, _html} = mount_island(conn, post, user)

    view
    |> element("#comment-form")
    |> render_submit(%{"comment" => %{"body" => "posted with **emphasis**"}})

    assert render(view) =~ "<strong>emphasis</strong>"
  end

  # --- A missing post -----------------------------------------------------------------

  test "a missing post renders the island empty (deleted mid-session)", %{conn: conn} do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(AccountsFixtures.user!())

    {:ok, view, html} =
      live_isolated(conn, FluxValeWeb.FeedbackLive.CommentsIsland,
        session: %{
          "user_token" => token,
          "slug" => "no-such-post"
        }
      )

    refute html =~ "data-testid='comments-island'"
    refute has_element?(view, "[data-testid='comments-island']")
  end
end
