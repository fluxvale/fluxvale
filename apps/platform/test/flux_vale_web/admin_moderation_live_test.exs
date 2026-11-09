defmodule FluxValeWeb.AdminModerationLiveTest do
  @moduledoc false

  # The feedback moderation surface (#501): the posts list with its
  # filter and search, the in-place expansion (sanitized body, votes,
  # comments, tags), and the moderation writes. The route gates here
  # are the shared live_session's arms (the anonymous 302 and the
  # non-admin 403, pinned once); every write path is additionally
  # pinned at the domain seam with a non-admin actor (Forbidden),
  # because the route gate is the only thing standing between a
  # non-admin and these views. Each destructive write is driven
  # confirmed-then-executed, plus its raced-refusal arm.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Feedback.Comment
  alias FluxVale.Feedback.Post
  alias FluxVale.Feedback.Tag
  alias FluxVale.Feedback.Vote
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.FeedbackFixtures
  alias FluxVale.TestSupport.SessionHelpers
  alias FluxValeWeb.AdminLive.Moderation

  require Ash.Query

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    admin =
      User.create!("admin-moderation-#{@n}@fluxvale.com", %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin), bare_conn: conn}
  end

  # -- preconditions ---------------------------------------------------------

  defp comment!(post, body, actor) do
    Comment.create!(%{post_id: post.id, body: body}, actor: actor)
  end

  # Votes run the paying gate; the platform admin passes it by policy,
  # so setup votes are cast by the admin actor.
  defp vote!(post, admin) do
    Vote.cast!(%{post_id: post.id}, actor: admin)
  end

  defp tag_count do
    Tag
    |> Ash.Query.for_read(:read, %{})
    |> Ash.count!(authorize?: false)
  end

  defp votes_for(post_id) do
    Vote
    |> Ash.Query.filter(post_id == ^post_id)
    |> Ash.read!(authorize?: false)
  end

  defp comments_for(post_id) do
    Comment
    |> Ash.Query.filter(post_id == ^post_id)
    |> Ash.read!(authorize?: false)
  end

  defp open_detail(view, post_id) do
    view
    |> element("[data-testid='admin-moderation-expand-#{post_id}']")
    |> render_click()
  end

  describe "the posts list" do
    test "an empty board says so honestly", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/moderation")

      assert has_element?(view, "[data-testid='admin-moderation']")

      assert has_element?(
               view,
               "[data-testid='admin-moderation-list'] p",
               "No posts on the board yet."
             )

      refute has_element?(view, "[data-testid^='admin-moderation-title-']")
    end

    test "lists posts with title, author, status badge, counts, and the posted stamp", %{
      conn: conn,
      admin: admin
    } do
      author = SessionHelpers.user!()
      post = FeedbackFixtures.post!(%{title: "Suspend from the CLI"})
      _comment = comment!(post, "one comment", author)
      _vote = vote!(post, admin)
      author_user = Ash.load!(post, :created_by_user, authorize?: false).created_by_user

      # The two tones that own their color alone rest uncued: the badge
      # renders without an icon (the status_cue fallback arm).
      done = FeedbackFixtures.post!(%{title: "Already done"})
      FeedbackFixtures.move_status!(done, :completed)
      rejected = FeedbackFixtures.post!(%{title: "Politely rejected"})
      FeedbackFixtures.move_status!(rejected, :declined)

      {:ok, view, _html} = live(conn, "/admin/moderation")

      assert has_element?(
               view,
               "[data-testid='admin-moderation-title-#{post.id}']",
               "Suspend from the CLI"
             )

      # The author is the account that filed the post.
      assert text_of(view, "[data-testid='admin-moderation-author-#{post.id}']") ==
               author_user.username

      assert has_element?(view, "[data-testid='admin-moderation-status-#{post.id}']", "Open")
      assert has_element?(view, "[data-testid='admin-moderation-votes-#{post.id}']", "1")

      assert has_element?(view, "[data-testid='admin-moderation-comments-#{post.id}']", "1")
      refute text_of(view, "[data-testid='admin-moderation-posted-#{post.id}']") == ""

      assert has_element?(view, "[data-testid='admin-moderation-status-#{done.id}']", "Completed")

      assert has_element?(
               view,
               "[data-testid='admin-moderation-status-#{rejected.id}']",
               "Declined"
             )
    end

    test "a system post with no author renders the empty author cell", %{conn: conn, admin: admin} do
      {:ok, org} = FluxVale.Accounts.personal_org_for_user(admin.id, authorize?: false)

      post =
        Post.create!(
          %{
            title: "System filed post",
            description: "No actor stamped this",
            organization_id: org.id
          },
          authorize?: false
        )

      {:ok, view, _html} = live(conn, "/admin/moderation")

      assert has_element?(view, "[data-testid='admin-moderation-title-#{post.id}']")
      assert text_of(view, "[data-testid='admin-moderation-author-#{post.id}']") == ""
    end

    test "rows run newest-first", %{conn: conn} do
      older = FeedbackFixtures.post!(%{title: "The older request"})
      newer = FeedbackFixtures.post!(%{title: "The newer request"})

      {:ok, view, _html} = live(conn, "/admin/moderation")

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.query(document, "[data-testid^='admin-moderation-title-']")

      titles =
        for match <- Enum.to_list(matches) do
          text = LazyHTML.text(match)
          String.trim(text)
        end

      assert titles == [newer.title, older.title]
    end

    test "real pagination replaces the old cap: a full first page and a second page", %{
      conn: conn
    } do
      oldest = FeedbackFixtures.post!(%{title: "The oldest post"})

      posts =
        for _n <- 1..25 do
          FeedbackFixtures.post!()
        end

      newest = List.last(posts)

      {:ok, view, _html} = live(conn, "/admin/moderation")

      # A full first page (newest first), the oldest post waiting on
      # page two. The count copy carries the honest total.
      assert has_element?(view, "[data-testid='admin-moderation-posts-count']", "1 to 25 of 26")

      assert has_element?(view, "[data-testid='admin-moderation-title-#{newest.id}']")
      refute has_element?(view, "[data-testid='admin-moderation-title-#{oldest.id}']")

      view
      |> element("[data-testid='admin-moderation-posts-page-next']")
      |> render_click()

      assert has_element?(view, "[data-testid='admin-moderation-title-#{oldest.id}']")

      assert has_element?(
               view,
               "[data-testid='admin-moderation-posts-page-label']",
               "Page 2 of 2"
             )

      assert_patched(view, "/admin/moderation?page=2")
    end

    test "the status filter narrows to the chosen status and All hands the list back", %{
      conn: conn
    } do
      open_post = FeedbackFixtures.post!(%{title: "Still open"})
      planned_post = FeedbackFixtures.post!(%{title: "Already planned"})
      FeedbackFixtures.move_status!(planned_post, :planned)

      {:ok, view, _html} = live(conn, "/admin/moderation")

      view
      |> element("[data-testid='admin-moderation-filter-planned']")
      |> render_click()

      assert has_element?(view, "[data-testid='admin-moderation-title-#{planned_post.id}']")
      refute has_element?(view, "[data-testid='admin-moderation-title-#{open_post.id}']")

      view
      |> element("[data-testid='admin-moderation-filter-all']")
      |> render_click()

      assert has_element?(view, "[data-testid='admin-moderation-title-#{open_post.id}']")
      assert has_element?(view, "[data-testid='admin-moderation-title-#{planned_post.id}']")
    end

    test "a crafted status value leaves the filter alone", %{conn: conn} do
      post = FeedbackFixtures.post!()

      {:ok, view, _html} = live(conn, "/admin/moderation")

      render_click(view, "filter-status", %{"status" => "not-a-status"})
      assert has_element?(view, "[data-testid='admin-moderation-title-#{post.id}']")

      render_click(view, "filter-status", %{"status" => %{"nested" => "map"}})
      assert has_element?(view, "[data-testid='admin-moderation-title-#{post.id}']")
    end

    test "search narrows by title and by author and never reaches past the list", %{
      conn: conn,
      admin: admin
    } do
      needle = SessionHelpers.user!()
      alpha = FeedbackFixtures.post!(%{title: "Alpha widget request"})
      _alpha_author = Ash.load!(alpha, :created_by_user, authorize?: false).created_by_user
      beta = FeedbackFixtures.post!(%{title: "Beta gadget request"})
      _comment = comment!(beta, "filed by the needle author", needle)

      # A post whose AUTHOR matches the needle but whose title does not.
      by_needle =
        Post.create!(
          %{title: "An unrelated title", description: "authored by the needle account"},
          actor: needle,
          authorize?: false
        )

      needle_username =
        Ash.load!(by_needle, :created_by_user, authorize?: false).created_by_user.username

      {:ok, view, _html} = live(conn, "/admin/moderation")

      render_change(view, "search", %{"search" => %{"query" => "Alpha widget"}})

      assert has_element?(view, "[data-testid='admin-moderation-title-#{alpha.id}']")
      refute has_element?(view, "[data-testid='admin-moderation-title-#{beta.id}']")

      render_change(view, "search", %{"search" => %{"query" => needle_username}})

      assert has_element?(view, "[data-testid='admin-moderation-title-#{by_needle.id}']")
      refute has_element?(view, "[data-testid='admin-moderation-title-#{alpha.id}']")

      render_change(view, "search", %{"search" => %{"query" => "zzz-no-such-post"}})

      assert has_element?(
               view,
               "[data-testid='admin-moderation-list'] p",
               "No post matches that search or filter."
             )

      # Clearing hands the whole list back.
      render_change(view, "search", %{"search" => %{"query" => ""}})

      assert has_element?(view, "[data-testid='admin-moderation-title-#{alpha.id}']")
      assert has_element?(view, "[data-testid='admin-moderation-title-#{beta.id}']")

      # The scope holds: the admin actor's own vote rows are not posts.
      refute has_element?(
               view,
               "[data-testid^='admin-moderation-title-']",
               to_string(AccountsFixtures.primary_address!(admin))
             )
    end
  end

  describe "the post expansion" do
    test "opens with the sanitized body, the tags, the votes, and the comments", %{
      conn: conn,
      admin: admin
    } do
      post = FeedbackFixtures.post!(%{description: "Plain body with a **bold** bit"})
      tag = FeedbackFixtures.tag!()
      FeedbackFixtures.tag_post!(post, [tag])
      comment = comment!(post, "A comment body", SessionHelpers.user!())
      vote = vote!(post, admin)

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, post.id)

      assert has_element?(view, "[data-testid='admin-moderation-detail-#{post.id}']")
      assert has_element?(view, "[data-testid='admin-moderation-post-tags']", tag.name)
      assert has_element?(view, "[data-testid='admin-moderation-post-body']", "Plain body")
      assert has_element?(view, "[data-testid='admin-moderation-vote-#{vote.id}']")
      assert has_element?(view, "[data-testid='admin-moderation-comment-#{comment.id}']")

      # The benign markdown rendered: the bold bit is markup, not asterisks.
      body_html = render(element(view, "[data-testid='admin-moderation-post-body']"))
      assert body_html =~ "<strong>bold</strong>"

      # The toggle closes it again.
      open_detail(view, post.id)
      refute has_element?(view, "[data-testid='admin-moderation-detail-#{post.id}']")
    end

    test "empty votes and comments read honestly", %{conn: conn} do
      post = FeedbackFixtures.post!()

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, post.id)

      assert has_element?(view, "[data-testid='admin-moderation-votes-empty']", "No votes yet.")

      assert has_element?(
               view,
               "[data-testid='admin-moderation-comments-empty']",
               "No comments yet."
             )
    end

    test "opening a post that vanished between render and click refreshes honestly", %{
      conn: conn
    } do
      post = FeedbackFixtures.post!()
      {:ok, view, _html} = live(conn, "/admin/moderation")
      Ash.destroy!(post, authorize?: false)

      render_click(view, "open-post", %{"id" => post.id})

      assert has_element?(view, "#flash-error", "gone from the board")
      refute has_element?(view, "[data-testid^='admin-moderation-detail-']")
    end

    test "raw HTML and hostile markdown never reach the admin render", %{conn: conn} do
      hostile =
        FeedbackFixtures.post!(%{
          description: """
          Hello <script>alert("xss")</script> world

          Click [here](javascript:alert(1)) or ![pic](https://evil.example/i.png)

          Visit [the docs](https://example.com/docs).
          """
        })

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, hostile.id)

      body_html = render(element(view, "[data-testid='admin-moderation-post-body']"))

      refute body_html =~ "<script"
      refute body_html =~ "javascript:"
      refute body_html =~ "<img"

      # The benign link survived the sanitizer.
      assert body_html =~ "https://example.com/docs"
    end

    test "comment bodies render through the same sanitizer", %{conn: conn} do
      post = FeedbackFixtures.post!()

      comment =
        comment!(post, "<script>bad()</script>\n\n**loud** words stay", SessionHelpers.user!())

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, post.id)

      comment_html =
        render(element(view, "[data-testid='admin-moderation-comment-#{comment.id}']"))

      refute comment_html =~ "<script"
      refute comment_html =~ "bad()"
      assert comment_html =~ "<strong>loud</strong>"
    end
  end

  describe "destroying a post" do
    test "the confirm names the consequence, cancel does nothing, confirm takes everything", %{
      conn: conn,
      admin: admin
    } do
      post = FeedbackFixtures.post!()
      _vote = vote!(post, admin)
      _comment = comment!(post, "a comment", SessionHelpers.user!())

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, post.id)

      view
      |> element("[data-testid='admin-moderation-destroy-post']")
      |> render_click()

      assert has_element?(view, "[data-testid='destructive-confirm']")

      assert has_element?(
               view,
               "[data-testid='destructive-confirm']",
               "votes and comments are removed with it"
             )

      assert has_element?(view, "[data-testid='admin-moderation-destroy-confirm']")
      assert has_element?(view, "[data-testid='admin-moderation-destroy-cancel']")

      # Cancel is a way out: the panel closes and nothing happened.
      view
      |> element("[data-testid='admin-moderation-destroy-cancel']")
      |> render_click()

      refute has_element?(view, "[data-testid='destructive-confirm']")
      assert has_element?(view, "[data-testid='admin-moderation-title-#{post.id}']")
      assert Ash.get!(Post, post.id, authorize?: false).id == post.id

      # This time the destructive button.
      view
      |> element("[data-testid='admin-moderation-destroy-post']")
      |> render_click()

      view
      |> element("[data-testid='admin-moderation-destroy-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-info", "votes and comments were removed with it")
      refute has_element?(view, "[data-testid='admin-moderation-title-#{post.id}']")

      # The dependent records went with it.
      assert [] = votes_for(post.id)
      assert [] = comments_for(post.id)
      assert {:error, _not_found} = Ash.get(Post, post.id, authorize?: false)
    end

    test "a referenced original shows the honest note and a disabled delete", %{conn: conn} do
      original = FeedbackFixtures.post!()
      duplicate = FeedbackFixtures.post!()
      FeedbackFixtures.move_status!(duplicate, :duplicate, duplicate_of: original)

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, original.id)

      assert has_element?(
               view,
               "[data-testid='admin-moderation-referenced-note']",
               "1 duplicate points at this post"
             )

      assert has_element?(
               view,
               "[data-testid='admin-moderation-referenced-note']",
               "refuses deletion"
             )

      assert render(element(view, "[data-testid='admin-moderation-destroy-post']")) =~
               "disabled"

      refute has_element?(view, "[data-testid='destructive-confirm']")

      # The post is untouched.
      assert Ash.get!(Post, original.id, authorize?: false).id == original.id
    end

    test "a duplicate landing between the render and the destroy reveal turns the click into the note",
         %{conn: conn} do
      post = FeedbackFixtures.post!()

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, post.id)

      # Unreferenced at render: the button is enabled. The duplicate
      # lands behind it.
      refute has_element?(view, "[data-testid='admin-moderation-referenced-note']")
      duplicate = FeedbackFixtures.post!()
      FeedbackFixtures.move_status!(duplicate, :duplicate, duplicate_of: post)

      view
      |> element("[data-testid='admin-moderation-destroy-post']")
      |> render_click()

      assert has_element?(view, "[data-testid='admin-moderation-referenced-note']")
      refute has_element?(view, "[data-testid='destructive-confirm']")
    end

    test "a duplicate planted behind the open confirm refuses at the action", %{conn: conn} do
      post = FeedbackFixtures.post!()

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, post.id)

      view
      |> element("[data-testid='admin-moderation-destroy-post']")
      |> render_click()

      assert has_element?(view, "[data-testid='destructive-confirm']")

      duplicate = FeedbackFixtures.post!()
      FeedbackFixtures.move_status!(duplicate, :duplicate, duplicate_of: post)

      view
      |> element("[data-testid='admin-moderation-destroy-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-error", "A duplicate now points at this post")
      assert has_element?(view, "[data-testid='admin-moderation-title-#{post.id}']")
      refute has_element?(view, "[data-testid='destructive-confirm']")
      assert Ash.get!(Post, post.id, authorize?: false).id == post.id
    end

    test "a post deleted behind the open confirm refuses and refreshes", %{conn: conn} do
      post = FeedbackFixtures.post!()

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, post.id)

      view
      |> element("[data-testid='admin-moderation-destroy-post']")
      |> render_click()

      Ash.destroy!(post, authorize?: false)

      view
      |> element("[data-testid='admin-moderation-destroy-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-error", "The post moved before the click")
      refute has_element?(view, "[data-testid='destructive-confirm']")
    end

    test "a destroy reveal naming a post that is already gone refreshes honestly", %{
      conn: conn
    } do
      post = FeedbackFixtures.post!()
      {:ok, view, _html} = live(conn, "/admin/moderation")
      Ash.destroy!(post, authorize?: false)

      render_click(view, "open-destroy-post", %{"id" => post.id})

      assert has_element?(view, "#flash-error", "gone from the board")
      refute has_element?(view, "[data-testid='destructive-confirm']")
    end

    test "a destroy reveal without an open panel is a stale frame and refreshes", %{
      conn: conn
    } do
      post = FeedbackFixtures.post!()
      {:ok, view, _html} = live(conn, "/admin/moderation")

      render_click(view, "open-destroy-post", %{"id" => post.id})

      assert has_element?(view, "#flash-error", "panel is no longer open")
      refute has_element?(view, "[data-testid='destructive-confirm']")
    end
  end

  describe "vote moderation" do
    test "retract confirms, then the vote leaves and the count drops", %{conn: conn, admin: admin} do
      post = FeedbackFixtures.post!()
      vote = vote!(post, admin)

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, post.id)

      view
      |> element("[data-testid='admin-moderation-retract-#{vote.id}']")
      |> render_click()

      # The vote's confirm is the light inline panel, not the heavy
      # danger grammar (reserved for the post destroy).
      assert has_element?(view, "[data-testid='admin-moderation-retract-panel']")

      assert has_element?(
               view,
               "[data-testid='admin-moderation-retract-panel']",
               "vote count drops by one"
             )

      # Cancel: nothing happened.
      view
      |> element("[data-testid='admin-moderation-retract-cancel']")
      |> render_click()

      refute has_element?(view, "[data-testid='admin-moderation-retract-panel']")
      assert Ash.get!(Post, post.id, authorize?: false).vote_count == 1

      # Execute.
      view
      |> element("[data-testid='admin-moderation-retract-#{vote.id}']")
      |> render_click()

      view
      |> element("[data-testid='admin-moderation-retract-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-info", "vote count dropped by one")
      refute has_element?(view, "[data-testid='admin-moderation-vote-#{vote.id}']")
      assert Ash.get!(Post, post.id, authorize?: false).vote_count == 0
      assert [] = votes_for(post.id)
    end

    test "a vote retracted behind the open panel refuses and refreshes", %{
      conn: conn,
      admin: admin
    } do
      post = FeedbackFixtures.post!()
      vote = vote!(post, admin)

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, post.id)

      view
      |> element("[data-testid='admin-moderation-retract-#{vote.id}']")
      |> render_click()

      assert has_element?(view, "[data-testid='admin-moderation-retract-panel']")
      assert Vote.retract!(vote, actor: admin) == :ok

      view
      |> element("[data-testid='admin-moderation-retract-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-error", "moved before the click")
      refute has_element?(view, "[data-testid='admin-moderation-retract-panel']")
    end

    test "a retract reveal naming a vote that is already gone refreshes honestly", %{
      conn: conn,
      admin: admin
    } do
      post = FeedbackFixtures.post!()
      vote = vote!(post, admin)
      assert Vote.retract!(vote, actor: admin) == :ok

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, post.id)

      render_click(view, "open-retract-vote", %{"id" => vote.id})

      assert has_element?(view, "#flash-error", "gone from the board")
      refute has_element?(view, "[data-testid='destructive-confirm']")
    end

    test "a refused retract (the counter cannot go negative) refreshes honestly", %{
      conn: conn,
      admin: admin
    } do
      post = FeedbackFixtures.post!()
      vote = vote!(post, admin)

      # The DB check constraint refuses the counter give-back when the
      # cached count does not back the vote (the forced-attribute seed
      # posture — no action accepts counters).
      post
      |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:vote_count, 0)
      |> Ash.update!(authorize?: false)

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, post.id)

      view
      |> element("[data-testid='admin-moderation-retract-#{vote.id}']")
      |> render_click()

      view
      |> element("[data-testid='admin-moderation-retract-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-error", "moved before the click")
      assert has_element?(view, "[data-testid='admin-moderation-vote-#{vote.id}']")
      assert [%{id: id}] = votes_for(post.id)
      assert id == vote.id
    end
  end

  describe "comment moderation" do
    test "delete confirms, then the comment leaves and the count drops", %{conn: conn} do
      post = FeedbackFixtures.post!()
      comment = comment!(post, "to be moderated", SessionHelpers.user!())

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, post.id)

      view
      |> element("[data-testid='admin-moderation-comment-delete-#{comment.id}']")
      |> render_click()

      assert has_element?(view, "[data-testid='destructive-confirm']")

      assert has_element?(
               view,
               "[data-testid='destructive-confirm']",
               "comment count drops by one"
             )

      view
      |> element("[data-testid='admin-moderation-comment-delete-cancel']")
      |> render_click()

      refute has_element?(view, "[data-testid='destructive-confirm']")
      assert Ash.get!(Post, post.id, authorize?: false).comment_count == 1

      view
      |> element("[data-testid='admin-moderation-comment-delete-#{comment.id}']")
      |> render_click()

      view
      |> element("[data-testid='admin-moderation-comment-delete-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-info", "comment count dropped by one")
      refute has_element?(view, "[data-testid='admin-moderation-comment-#{comment.id}']")
      assert Ash.get!(Post, post.id, authorize?: false).comment_count == 0
      assert [] = comments_for(post.id)
    end

    test "a comment deleted behind the open panel refuses and refreshes", %{
      conn: conn,
      admin: admin
    } do
      post = FeedbackFixtures.post!()
      comment = comment!(post, "raced", admin)

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, post.id)

      view
      |> element("[data-testid='admin-moderation-comment-delete-#{comment.id}']")
      |> render_click()

      Ash.destroy!(comment, authorize?: false)

      view
      |> element("[data-testid='admin-moderation-comment-delete-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-error", "moved before the click")
      refute has_element?(view, "[data-testid='destructive-confirm']")
    end

    test "a delete reveal naming a comment that is already gone refreshes honestly", %{
      conn: conn,
      admin: admin
    } do
      post = FeedbackFixtures.post!()
      comment = comment!(post, "gone", admin)
      Ash.destroy!(comment, authorize?: false)

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, post.id)

      render_click(view, "open-delete-comment", %{"id" => comment.id})

      assert has_element?(view, "#flash-error", "gone from the board")
      refute has_element?(view, "[data-testid='destructive-confirm']")
    end

    test "a refused comment delete (the counter cannot go negative) refreshes honestly", %{
      conn: conn,
      admin: admin
    } do
      post = FeedbackFixtures.post!()
      comment = comment!(post, "zero-backed", admin)

      post
      |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:comment_count, 0)
      |> Ash.update!(authorize?: false)

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, post.id)

      view
      |> element("[data-testid='admin-moderation-comment-delete-#{comment.id}']")
      |> render_click()

      view
      |> element("[data-testid='admin-moderation-comment-delete-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-error", "moved before the click")
      assert has_element?(view, "[data-testid='admin-moderation-comment-#{comment.id}']")
      assert [%{id: id}] = comments_for(post.id)
      assert id == comment.id
    end
  end

  describe "the tag vocabulary" do
    test "the create form derives the slug from the name when the slug is blank", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/moderation")

      view
      |> element("#admin-moderation-tag-create")
      |> render_submit(%{"tag" => %{"name" => "Accessibility", "slug" => ""}})

      assert has_element?(view, "#flash-info", "Tag created.")
      assert {:ok, tag} = Tag.get_by_slug("accessibility", authorize?: false)
      assert tag.name == "Accessibility"
      assert has_element?(view, "[data-testid='admin-moderation-tag-usage-#{tag.id}']", "0")
    end

    test "an authored slug is kept", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/moderation")

      view
      |> element("#admin-moderation-tag-create")
      |> render_submit(%{"tag" => %{"name" => "Wide mode", "slug" => "wide-mode"}})

      assert has_element?(view, "#flash-info", "Tag created.")
      assert {:ok, _tag} = Tag.get_by_slug("wide-mode", authorize?: false)
    end

    test "an invalid tag is refused inline and nothing is written", %{conn: conn} do
      before = tag_count()
      {:ok, view, _html} = live(conn, "/admin/moderation")

      view
      |> element("#admin-moderation-tag-create")
      |> render_submit(%{"tag" => %{"name" => "x", "slug" => ""}})

      refute has_element?(view, "#flash-info", "Tag created.")
      assert tag_count() == before

      # A hostile slug fails the slug constraint inline too.
      view
      |> element("#admin-moderation-tag-create")
      |> render_submit(%{"tag" => %{"name" => "Valid name", "slug" => "Not A Slug"}})

      refute has_element?(view, "#flash-info", "Tag created.")
      assert tag_count() == before
    end

    test "keystroke validation of the create form keeps the form honest", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/moderation")

      # A keystroke without a slug key reaches the form (the name-only
      # shape: the slug stays nil, so DeriveSlug still runs on submit).
      render_change(view, "validate-tag", %{"tag" => %{"name" => "Partial name"}})
      refute has_element?(view, "#flash-info", "Tag created.")

      view
      |> element("#admin-moderation-tag-create")
      |> render_submit(%{"tag" => %{"name" => "Keystroke tag"}})

      assert has_element?(view, "#flash-info", "Tag created.")
      assert {:ok, _tag} = Tag.get_by_slug("keystroke-tag", authorize?: false)
    end

    test "rename opens under its row, saves, and cancels cleanly", %{conn: conn} do
      tag = FeedbackFixtures.tag!()
      {:ok, view, _html} = live(conn, "/admin/moderation")

      view
      |> element("[data-testid='admin-moderation-tag-rename-#{tag.id}']")
      |> render_click()

      assert has_element?(view, "#admin-moderation-tag-rename")

      view
      |> element("[data-testid='admin-moderation-tag-rename-cancel']")
      |> render_click()

      refute has_element?(view, "#admin-moderation-tag-rename")

      view
      |> element("[data-testid='admin-moderation-tag-rename-#{tag.id}']")
      |> render_click()

      view
      |> element("#admin-moderation-tag-rename")
      |> render_submit(%{"tag_rename" => %{"name" => "Renamed vocabulary"}})

      assert has_element?(view, "#flash-info", "Tag renamed.")

      assert has_element?(
               view,
               "[data-testid='admin-moderation-tag-name-#{tag.id}']",
               "Renamed vocabulary"
             )

      assert Ash.get!(Tag, tag.id, authorize?: false).name == "Renamed vocabulary"
    end

    test "a blank rename is refused inline", %{conn: conn} do
      tag = FeedbackFixtures.tag!()
      {:ok, view, _html} = live(conn, "/admin/moderation")

      view
      |> element("[data-testid='admin-moderation-tag-rename-#{tag.id}']")
      |> render_click()

      view
      |> element("#admin-moderation-tag-rename")
      |> render_submit(%{"tag_rename" => %{"name" => "   "}})

      refute has_element?(view, "#flash-info", "Tag renamed.")
      assert Ash.get!(Tag, tag.id, authorize?: false).name == tag.name
      # The form stays open with its error.
      assert has_element?(view, "#admin-moderation-tag-rename")

      # A keystroke rides the change event. A submit whose payload has
      # no usable name key is refused inline: the missing key trims to
      # an empty name, which fails the length check, and the form stays
      # open. (The inner map must carry a key: an empty nested map
      # URL-encodes as a bare string and never reaches the clause.)
      render_change(view, "validate-tag-rename", %{"tag_rename" => %{"name" => "Half typed"}})
      render_submit(view, "save-tag-rename", %{"tag_rename" => %{"other" => "x"}})

      refute has_element?(view, "#flash-info", "Tag renamed.")
      assert Ash.get!(Tag, tag.id, authorize?: false).name == tag.name
      assert has_element?(view, "#admin-moderation-tag-rename")
    end

    test "destroying a USED tag confirms the untag consequence, then takes the pairings", %{
      conn: conn
    } do
      tag = FeedbackFixtures.tag!()
      post = FeedbackFixtures.post!()
      FeedbackFixtures.tag_post!(post, [tag])

      {:ok, view, _html} = live(conn, "/admin/moderation")

      view
      |> element("[data-testid='admin-moderation-tag-delete-#{tag.id}']")
      |> render_click()

      assert has_element?(view, "[data-testid='destructive-confirm']")

      assert has_element?(
               view,
               "[data-testid='destructive-confirm']",
               "1 post carries it today"
             )

      # Cancel: the pairing survives.
      view
      |> element("[data-testid='admin-moderation-tag-delete-cancel']")
      |> render_click()

      refute has_element?(view, "[data-testid='destructive-confirm']")
      assert {:ok, _tag} = Tag.get_by_slug(tag.slug, authorize?: false)

      view
      |> element("[data-testid='admin-moderation-tag-delete-#{tag.id}']")
      |> render_click()

      view
      |> element("[data-testid='admin-moderation-tag-delete-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-info", "Tag deleted.")
      assert {:error, _not_found} = Tag.get_by_slug(tag.slug, authorize?: false)

      # The expansion no longer carries the chip.
      open_detail(view, post.id)
      refute has_element?(view, "[data-testid='admin-moderation-post-tags']")
    end

    test "destroying an UNUSED tag is one click, no ceremony", %{conn: conn} do
      tag = FeedbackFixtures.tag!()
      {:ok, view, _html} = live(conn, "/admin/moderation")

      view
      |> element("[data-testid='admin-moderation-tag-delete-#{tag.id}']")
      |> render_click()

      assert has_element?(view, "#flash-info", "Tag deleted.")
      refute has_element?(view, "[data-testid='destructive-confirm']")
      assert {:error, _not_found} = Tag.get_by_slug(tag.slug, authorize?: false)
    end

    test "a tag deleted behind the open confirm refuses and refreshes", %{conn: conn} do
      tag = FeedbackFixtures.tag!()
      post = FeedbackFixtures.post!()
      FeedbackFixtures.tag_post!(post, [tag])

      {:ok, view, _html} = live(conn, "/admin/moderation")

      view
      |> element("[data-testid='admin-moderation-tag-delete-#{tag.id}']")
      |> render_click()

      Ash.destroy!(tag, authorize?: false)

      view
      |> element("[data-testid='admin-moderation-tag-delete-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-error", "moved before the click")
      refute has_element?(view, "[data-testid='destructive-confirm']")
    end

    test "a tag delete naming a tag that is already gone refreshes honestly", %{conn: conn} do
      tag = FeedbackFixtures.tag!()
      Ash.destroy!(tag, authorize?: false)

      {:ok, view, _html} = live(conn, "/admin/moderation")

      render_click(view, "open-delete-tag", %{"id" => tag.id})

      assert has_element?(view, "#flash-error", "gone from the board")
      refute has_element?(view, "[data-testid='destructive-confirm']")
    end

    test "a rename reveal naming a tag that is already gone refreshes honestly", %{conn: conn} do
      tag = FeedbackFixtures.tag!()
      Ash.destroy!(tag, authorize?: false)

      {:ok, view, _html} = live(conn, "/admin/moderation")

      render_click(view, "open-rename-tag", %{"id" => tag.id})

      assert has_element?(view, "#flash-error", "gone from the board")
      refute has_element?(view, "#admin-moderation-tag-rename")
    end

    test "an empty vocabulary says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/moderation")

      assert has_element?(
               view,
               "[data-testid='admin-moderation-tags-empty']",
               "No tags yet"
             )
    end
  end

  describe "the review fixes" do
    test "an ownerless seed-shaped vote expands with an honest unknown caster", %{
      conn: conn,
      admin: admin
    } do
      post = FeedbackFixtures.post!()
      {:ok, org} = FluxVale.Accounts.personal_org_for_user(admin.id, authorize?: false)

      # The demo seeder's exact shape: a cast with no actor, the org
      # named, running authorize?: false (cast_demo_vote!).
      Vote
      |> Ash.Changeset.for_create(
        :cast,
        %{post_id: post.id, organization_id: org.id},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, post.id)

      # No crash, and the ownerless row reads honestly.
      assert has_element?(view, "[data-testid='admin-moderation-votes']")
      assert has_element?(view, "[data-testid^='admin-moderation-vote-']")

      assert has_element?(
               view,
               "[data-testid='admin-moderation-votes']",
               "Unknown caster"
             )

      # The moderation levers stay reachable for a seeded post.
      assert has_element?(view, "[data-testid='admin-moderation-destroy-post']")
    end

    test "opening a second tag confirm closes the first: one panel, acting on its own row", %{
      conn: conn
    } do
      tag_one = FeedbackFixtures.tag!()
      tag_two = FeedbackFixtures.tag!()
      post = FeedbackFixtures.post!()
      FeedbackFixtures.tag_post!(post, [tag_one, tag_two])

      {:ok, view, _html} = live(conn, "/admin/moderation")

      view
      |> element("[data-testid='admin-moderation-tag-delete-#{tag_one.id}']")
      |> render_click()

      assert has_element?(view, "[data-testid='destructive-confirm']")
      assert has_element?(view, "[data-testid='destructive-confirm']", tag_one.name)

      # The second reveal: the reset collapses the first panel.
      view
      |> element("[data-testid='admin-moderation-tag-delete-#{tag_two.id}']")
      |> render_click()

      # One panel in the DOM, and it names tag_two.
      assert has_element?(view, "[data-testid='destructive-confirm']", tag_two.name)
      refute has_element?(view, "[data-testid='destructive-confirm']", tag_one.name)

      # Executing acts on tag_two, not tag_one (the probe-proven
      # wrong-record arm).
      view
      |> element("[data-testid='admin-moderation-tag-delete-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-info", "Tag deleted.")
      assert {:ok, _tag} = Tag.get_by_slug(tag_one.slug, authorize?: false)
      assert {:error, _gone} = Tag.get_by_slug(tag_two.slug, authorize?: false)
    end

    test "opening a second expansion closes the first", %{conn: conn} do
      alpha = FeedbackFixtures.post!(%{title: "Expansion alpha"})
      beta = FeedbackFixtures.post!(%{title: "Expansion beta"})

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, alpha.id)
      assert has_element?(view, "[data-testid='admin-moderation-detail-#{alpha.id}']")

      open_detail(view, beta.id)

      refute has_element?(view, "[data-testid='admin-moderation-detail-#{alpha.id}']")
      assert has_element?(view, "[data-testid='admin-moderation-detail-#{beta.id}']")
    end

    test "a crafted retract reveal naming a vote the open panel does not hold expires quietly", %{
      conn: conn,
      admin: admin
    } do
      shown_post = FeedbackFixtures.post!()
      other_post = FeedbackFixtures.post!()
      other_vote = vote!(other_post, admin)

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, shown_post.id)

      render_click(view, "open-retract-vote", %{"id" => other_vote.id})

      assert has_element?(view, "#flash-error", "panel is no longer open")
      refute has_element?(view, "[data-testid='admin-moderation-retract-panel']")
      refute has_element?(view, "[data-testid^='admin-moderation-detail-']")
    end

    test "a crafted comment reveal naming a comment the open panel does not hold expires quietly",
         %{conn: conn} do
      shown_post = FeedbackFixtures.post!()
      other_post = FeedbackFixtures.post!()
      other_comment = comment!(other_post, "on another post", SessionHelpers.user!())

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, shown_post.id)

      render_click(view, "open-delete-comment", %{"id" => other_comment.id})

      assert has_element?(view, "#flash-error", "panel is no longer open")
      refute has_element?(view, "[data-testid='destructive-confirm']")
    end

    test "the tag form events with no rename open are silent no-ops", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/moderation")

      render_change(view, "validate-tag-rename", %{"tag_rename" => %{"name" => "Crafted"}})
      render_submit(view, "save-tag-rename", %{"tag_rename" => %{"name" => "Crafted"}})

      refute has_element?(view, "#flash-error")
      refute has_element?(view, "#flash-info", "Tag renamed.")
    end

    test "a crafted search query that is not a string is a no-op", %{conn: conn} do
      post = FeedbackFixtures.post!()
      {:ok, view, _html} = live(conn, "/admin/moderation")

      render_change(view, "search", %{"search" => %{"query" => %{"nested" => "map"}}})

      assert has_element?(view, "[data-testid='admin-moderation-title-#{post.id}']")
    end

    test "the refusal classifier names every duplicate error class" do
      invalid = %Ash.Error.Invalid{errors: [%{field: :duplicate_of_id, message: "refused"}]}
      assert Moderation.referenced_refusal?(invalid)

      # The truly-concurrent race loses at the duplicate_of FK, which
      # Ash wraps as Unknown-class.
      unknown_fk = %Ash.Error.Unknown{errors: [%{field: :duplicate_of_id, message: "fk"}]}
      assert Moderation.referenced_refusal?(unknown_fk)

      unknown_other = %Ash.Error.Unknown{errors: [%{field: :other, message: "fk"}]}
      refute Moderation.referenced_refusal?(unknown_other)

      refute Moderation.referenced_refusal?(%Ash.Error.Query.NotFound{})
    end

    test "a referenced original disables its delete button with the reason attached", %{
      conn: conn
    } do
      original = FeedbackFixtures.post!()
      duplicate = FeedbackFixtures.post!()
      FeedbackFixtures.move_status!(duplicate, :duplicate, duplicate_of: original)

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, original.id)

      assert has_element?(view, "[data-testid='admin-moderation-referenced-note']")

      assert has_element?(
               view,
               "[data-testid='admin-moderation-referenced-note']",
               "Delete the duplicate first"
             )

      assert render(element(view, "[data-testid='admin-moderation-destroy-post']")) =~
               "disabled"
    end

    test "the duplicate note plurals across counts", %{conn: conn} do
      pair_original = FeedbackFixtures.post!()
      five_original = FeedbackFixtures.post!()

      duplicates =
        for _n <- 1..2 do
          dup = FeedbackFixtures.post!()
          FeedbackFixtures.move_status!(dup, :duplicate, duplicate_of: pair_original)
          dup
        end

      for _n <- 1..5 do
        dup = FeedbackFixtures.post!()
        FeedbackFixtures.move_status!(dup, :duplicate, duplicate_of: five_original)
      end

      {:ok, view, _html} = live(conn, "/admin/moderation")

      # The duplicate rows carry their own shape cue (the link, for the
      # pointer to the original) — the neutral-tone collision with Open.
      first_duplicate = List.first(duplicates)

      assert has_element?(
               view,
               "[data-testid='admin-moderation-status-#{first_duplicate.id}'] .hero-link"
             )

      open_detail(view, pair_original.id)

      assert has_element?(
               view,
               "[data-testid='admin-moderation-referenced-note']",
               "2 duplicates point at this post"
             )

      open_detail(view, five_original.id)

      assert has_element?(
               view,
               "[data-testid='admin-moderation-referenced-note']",
               "5 duplicates point at this post"
             )
    end

    test "the used-tag confirm plurals across counts", %{conn: conn} do
      tag = FeedbackFixtures.tag!()
      post = FeedbackFixtures.post!()
      FeedbackFixtures.tag_post!(post, [tag])

      {:ok, view, _html} = live(conn, "/admin/moderation")

      view
      |> element("[data-testid='admin-moderation-tag-delete-#{tag.id}']")
      |> render_click()

      assert has_element?(view, "[data-testid='destructive-confirm']", "1 post carries it today")

      view
      |> element("[data-testid='admin-moderation-tag-delete-cancel']")
      |> render_click()

      # Two and five: the ngettext plural arms. The count is the POSTS
      # carrying the tag, so each arm tags more posts.
      two = Enum.map(1..1, fn _n -> FeedbackFixtures.post!() end)
      Enum.each(two, &FeedbackFixtures.tag_post!(&1, [tag]))

      view
      |> element("[data-testid='admin-moderation-tag-delete-#{tag.id}']")
      |> render_click()

      assert has_element?(view, "[data-testid='destructive-confirm']", "2 posts carry it today")

      view
      |> element("[data-testid='admin-moderation-tag-delete-cancel']")
      |> render_click()

      more = Enum.map(1..3, fn _n -> FeedbackFixtures.post!() end)
      Enum.each(more, &FeedbackFixtures.tag_post!(&1, [tag]))

      view
      |> element("[data-testid='admin-moderation-tag-delete-#{tag.id}']")
      |> render_click()

      assert has_element?(view, "[data-testid='destructive-confirm']", "5 posts carry it today")

      view
      |> element("[data-testid='admin-moderation-tag-delete-cancel']")
      |> render_click()
    end

    test "the tag confirm re-reads the count at click time", %{conn: conn} do
      tag = FeedbackFixtures.tag!()
      post = FeedbackFixtures.post!()
      other = FeedbackFixtures.post!()
      FeedbackFixtures.tag_post!(post, [tag])

      {:ok, view, _html} = live(conn, "/admin/moderation")

      view
      |> element("[data-testid='admin-moderation-tag-delete-#{tag.id}']")
      |> render_click()

      assert has_element?(view, "[data-testid='destructive-confirm']", "1 post carries it today")

      # The count drifts while the panel is up.
      FeedbackFixtures.tag_post!(other, [tag])

      view
      |> element("[data-testid='admin-moderation-tag-delete-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-info", "Tag deleted.")
      assert {:error, _gone} = Tag.get_by_slug(tag.slug, authorize?: false)
    end

    test "the expansion meta does not stutter the status word", %{conn: conn} do
      post = FeedbackFixtures.post!()
      FeedbackFixtures.move_status!(post, :started)

      {:ok, view, _html} = live(conn, "/admin/moderation")
      open_detail(view, post.id)

      meta = render(element(view, "[data-testid='admin-moderation-detail-#{post.id}']"))
      refute meta =~ "Started Started"
      assert meta =~ "Started"
    end
  end

  describe "the shape-guard no-ops" do
    test "confirm clicks with nothing pending do nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/moderation")

      render_click(view, "confirm-destroy-post", %{})
      render_click(view, "confirm-retract-vote", %{})
      render_click(view, "confirm-delete-comment", %{})
      render_click(view, "confirm-delete-tag", %{})

      refute has_element?(view, "#flash-error")
      refute has_element?(view, "#flash-info")
    end

    test "cancel-confirm with nothing pending is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/moderation")

      render_click(view, "cancel-confirm", %{})

      refute has_element?(view, "#flash-error")
    end

    test "cancel-rename with nothing pending is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/moderation")

      render_click(view, "cancel-rename-tag", %{})

      refute has_element?(view, "#admin-moderation-tag-rename")
    end

    test "malformed form events are silent no-ops", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/moderation")

      render_change(view, "validate-tag", %{"nope" => "x"})
      render_submit(view, "create-tag", %{"nope" => "x"})
      render_change(view, "validate-tag-rename", %{"nope" => "x"})
      render_submit(view, "save-tag-rename", %{"nope" => "x"})

      refute has_element?(view, "#flash-error")
    end
  end

  describe "the shell and the gates" do
    test "the sidebar marks the feedback entry live and exact", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/moderation")

      assert has_element?(view, "[data-testid='admin-nav-feedback'][aria-current='page']")
      assert has_element?(view, "[data-testid='admin-nav-feedback']", "Feedback moderation")
      refute has_element?(view, "[data-testid='admin-coming-feedback']")
      # The console's completing flip: wallets, feedback, orgs, and
      # gateways all link, and no Coming badge renders anywhere (the
      # shell's grammar branch retired with the last flip).
      assert has_element?(view, "[data-testid='admin-nav-wallets'][href]")
      assert has_element?(view, "[data-testid='admin-nav-orgs'][href]")
      assert has_element?(view, "[data-testid='admin-nav-gateways'][href='/admin/gateways']")
      refute has_element?(view, "[data-testid^='admin-coming-']")
    end

    test "anonymous bounces to /sign-in", %{bare_conn: conn} do
      conn = get(conn, "/admin/moderation")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "a signed-in non-admin gets a bare 403", %{bare_conn: conn} do
      user = SessionHelpers.user!()
      signed = SessionHelpers.sign_in(conn, user)
      conn = get(signed, "/admin/moderation")

      assert conn.status == 403
    end

    test "non-admin actors are Forbidden on every write path", %{admin: admin} do
      non_admin = SessionHelpers.user!()
      post = FeedbackFixtures.post!()
      comment = comment!(post, "body", admin)
      tag = FeedbackFixtures.tag!()
      vote = vote!(post, admin)

      # The paying gate's own rule admits a paid org's owner on votes;
      # a plain user is not one, and that gate is the domain's, not this
      # surface's to weaken.
      assert {:error, %Ash.Error.Forbidden{}} = Vote.retract(vote, actor: non_admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(post, actor: non_admin, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(comment, actor: non_admin, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Tag
               |> Ash.Changeset.for_create(:create, %{name: "Nope"},
                 actor: non_admin,
                 authorize?: true
               )
               |> Ash.create()

      assert {:error, %Ash.Error.Forbidden{}} =
               tag
               |> Ash.Changeset.for_update(:update, %{name: "Nope"},
                 actor: non_admin,
                 authorize?: true
               )
               |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(tag, actor: non_admin, authorize?: true)
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
end
