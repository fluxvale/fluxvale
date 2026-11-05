defmodule FluxValeWeb.FeedbackControllerTest do
  @moduledoc false

  # async: true — pure sandbox DB reads, no global state (the blog's
  # persistent_term posture does not apply here).

  use FluxValeWeb.ConnCase, async: true

  import FluxVale.TestSupport.FeedbackFixtures

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.Category
  alias FluxVale.Feedback.Comment
  alias FluxVale.TestSupport.AccountsFixtures

  defp position(html, needle) do
    assert html =~ needle

    {pos, _len} = :binary.match(html, needle)
    pos
  end

  defp row_count(html) do
    segments = String.split(html, ~s(data-testid="feedback-post-))
    length(segments) - 1
  end

  # Catalog fixture for the tag cross-link convention (T10): a tag whose
  # slug matches a catalog app rides the /apps/:slug link.
  defp catalog_app!(slug) do
    n = System.unique_integer()

    category =
      Category.create!(
        %{name: "Media #{n}", slug: "media-#{n}", description: "Read things"},
        authorize?: false
      )

    App.create!(
      %{
        name: String.capitalize(slug),
        slug: slug,
        tagline: "Reading server",
        category_id: category.id
      },
      authorize?: false
    )
  end

  describe "GET /feedback" do
    test "answers 200 anonymously with the board head and chrome", %{conn: conn} do
      post = post!(%{title: "Add dark mode toggles", description: "Please"})

      conn = get(conn, ~p"/feedback")
      html = html_response(conn, 200)

      assert conn.status == 200
      assert html =~ "Add dark mode toggles"
      assert html =~ "data-testid=\"feedback-post-#{post.slug}\""
      assert html =~ "Feedback · FluxVale</title>"

      # The public chrome's footer carries the board link.
      assert html =~ "data-testid=\"footer-feedback\""
    end

    test "the header carries the composer CTA (the write is reachable from the board)", %{
      conn: conn
    } do
      html = html_response(get(conn, ~p"/feedback"), 200)

      assert html =~ "data-testid=\"composer-cta\""
      assert html =~ "href=\"/feedback/new\""
      assert html =~ "Post a request"
    end

    test "rows show status badge, counts, and the posted age", %{conn: conn} do
      post = post!(%{title: "Badge and counters row", description: "Row anatomy"})
      set_counters!(post, 7, 3)

      html = html_response(get(conn, ~p"/feedback"), 200)

      assert html =~ "7 votes"
      assert html =~ "3 comments"
      assert html =~ "Open"
      assert html =~ "Posted"
      assert html =~ "data-testid=\"feedback-status\""
    end

    test "the default view excludes duplicates", %{conn: conn} do
      post!(%{title: "Visible open request", description: "x"})
      original = post!(%{title: "Original request", description: "x"})
      dup = post!(%{title: "Folded duplicate request", description: "x"})
      move_status!(dup, :duplicate, duplicate_of: original)

      html = html_response(get(conn, ~p"/feedback"), 200)

      assert html =~ "Visible open request"
      assert html =~ "Original request"
      refute html =~ "Folded duplicate request"
    end

    test "sort=top orders by votes desc (the default)", %{conn: conn} do
      low = post!(%{title: "Low votes here", description: "x"})
      set_counters!(low, 2, 0)
      high = post!(%{title: "High votes here", description: "x"})
      set_counters!(high, 50, 0)

      default_html = html_response(get(conn, ~p"/feedback"), 200)
      top_html = html_response(get(conn, ~p"/feedback?sort=top"), 200)

      for html <- [default_html, top_html] do
        assert position(html, "High votes here") < position(html, "Low votes here")
      end
    end

    test "equal votes fall back to fresher first", %{conn: conn} do
      post!(%{title: "First created equal", description: "x"})
      post!(%{title: "Second created equal", description: "x"})

      html = html_response(get(conn, ~p"/feedback?sort=top"), 200)

      assert position(html, "Second created equal") < position(html, "First created equal")
    end

    test "sort=new orders by recency regardless of votes", %{conn: conn} do
      popular = post!(%{title: "Popular old request", description: "x"})
      set_counters!(popular, 99, 0)
      post!(%{title: "Fresh new request", description: "x"})

      html = html_response(get(conn, ~p"/feedback?sort=new"), 200)

      assert position(html, "Fresh new request") < position(html, "Popular old request")
    end

    test "an unknown sort falls back to top", %{conn: conn} do
      low = post!(%{title: "Fallback low votes", description: "x"})
      set_counters!(low, 1, 0)
      high = post!(%{title: "Fallback high votes", description: "x"})
      set_counters!(high, 9, 0)

      html = html_response(get(conn, ~p"/feedback?sort=bogus"), 200)

      assert position(html, "Fallback high votes") < position(html, "Fallback low votes")
    end

    test "a status filter narrows the board", %{conn: conn} do
      post!(%{title: "Stays open request", description: "x"})
      planned = post!(%{title: "Planned for next quarter", description: "x"})
      move_status!(planned, :planned)

      html = html_response(get(conn, ~p"/feedback?status=planned"), 200)

      assert html =~ "Planned for next quarter"
      refute html =~ "Stays open request"
    end

    test "the duplicate chip lists duplicates", %{conn: conn} do
      original = post!(%{title: "Chip original", description: "x"})
      dup = post!(%{title: "Chip duplicate", description: "x"})
      move_status!(dup, :duplicate, duplicate_of: original)

      html = html_response(get(conn, ~p"/feedback?status=duplicate"), 200)

      assert html =~ "Chip duplicate"
      refute html =~ "Chip original"
    end

    test "an unknown status falls back to the default view", %{conn: conn} do
      original = post!(%{title: "Unknown status original", description: "x"})
      dup = post!(%{title: "Unknown status duplicate", description: "x"})
      move_status!(dup, :duplicate, duplicate_of: original)

      html = html_response(get(conn, ~p"/feedback?status=bogus"), 200)

      assert html =~ "Unknown status original"
      refute html =~ "Unknown status duplicate"
    end

    test "an empty filtered view renders the filtered empty state", %{conn: conn} do
      html = html_response(get(conn, ~p"/feedback?status=completed"), 200)

      assert html =~ "No posts with this status yet."
      refute html =~ "data-testid=\"feedback-post-"
    end

    test "a zero-match filter on a populated board keeps the filtered copy", %{conn: conn} do
      # The empty-DB tests cannot catch copy that lies the other way: a
      # populated board whose filter matches nothing must not claim the
      # board has no posts.
      post!(%{title: "Populated board open request", description: "x"})

      html = html_response(get(conn, ~p"/feedback?status=completed"), 200)

      assert html =~ "No posts with this status yet."
      refute html =~ "No posts yet."
      # The board is populated — the row is filtered out, not absent.
      refute html =~ "Populated board open request"
      assert html =~ "Open"
    end

    test "an unfiltered empty board renders the same empty state (prod at launch)", %{
      conn: conn
    } do
      html = html_response(get(conn, ~p"/feedback"), 200)

      assert html =~ "No posts yet."
      refute html =~ "No posts with this status yet."
      refute html =~ "data-testid=\"feedback-post-"
      # The chrome stays: the footer's board link and the sort/filter
      # toolbar render even with nothing to list.
      assert html =~ "data-testid=\"footer-feedback\""
    end

    test "pagination walks a page past the size boundary", %{conn: conn} do
      for n <- 1..21 do
        post!(%{title: "Bulk request #{String.pad_leading(Integer.to_string(n), 3, "0")}"})
      end

      page_one = html_response(get(conn, ~p"/feedback"), 200)
      assert row_count(page_one) == 20
      assert page_one =~ "Page 1 of 2"
      assert page_one =~ "Next"

      page_two = html_response(get(conn, ~p"/feedback?page=2"), 200)
      assert row_count(page_two) == 1
      assert page_two =~ "Bulk request 001"
      assert page_two =~ "Previous"
      refute page_two =~ "Next"
    end

    test "garbage page params read as page one", %{conn: conn} do
      for n <- 1..21 do
        post!(%{
          title: "Garbage page request #{String.pad_leading(Integer.to_string(n), 3, "0")}"
        })
      end

      for page_param <- ["abc", "0", "-3"] do
        html = html_response(get(conn, "/feedback?page=#{page_param}"), 200)
        assert row_count(html) == 20
        assert html =~ "Page 1 of 2"
      end

      # A repeated/indexed page key is not a number either.
      indexed = html_response(get(conn, "/feedback?page[]=2"), 200)
      assert row_count(indexed) == 20
    end

    test "a huge page number clamps to the cap instead of 500ing", %{conn: conn} do
      # 20 digits parses as an arbitrary-precision integer; the raw
      # offset would overflow Postgrex's int8 bind (the #426 hostile
      # finding). The clamp keeps the request a 200.
      for n <- 1..21 do
        post!(%{title: "Clamp page request #{String.pad_leading(Integer.to_string(n), 3, "0")}"})
      end

      huge = html_response(get(conn, "/feedback?page=99999999999999999999"), 200)

      assert huge =~ "Page 10000 of"

      # At the cap the window is empty, so the page reads honestly.
      assert huge =~ "No posts yet."
      refute huge =~ "data-testid=\"feedback-post-"
    end
  end

  describe "GET /feedback/new" do
    # The fixed route the router declares before :show (the /blog/feed
    # lesson); a GET must serve the composer, never the :slug capture.
    test "serves the composer with the anonymous CTA", %{conn: conn} do
      conn = get(conn, ~p"/feedback/new")

      assert conn.status == 200
      assert html_response(conn, 200) =~ "Sign in to post a request."
    end
  end

  describe "GET /feedback/:slug" do
    test "renders the post with the full SEO head", %{conn: conn} do
      post =
        post!(%{
          title: "Add an onboarding checklist",
          description: "New orgs need a guided first run."
        })

      set_counters!(post, 7, 2)

      conn = get(conn, ~p"/feedback/#{post.slug}")
      html = html_response(conn, 200)

      assert html =~ "Add an onboarding checklist - 7 votes - FluxVale</title>"
      assert html =~ "rel=\"canonical\" href=\"https://fluxvale.com/feedback/#{post.slug}\""

      assert html =~
               "property=\"og:title\" content=\"Add an onboarding checklist - 7 votes - FluxVale\""

      assert html =~
               "property=\"og:url\" content=\"https://fluxvale.com/feedback/#{post.slug}\""

      assert html =~ "name=\"twitter:card\" content=\"summary_large_image\""

      assert html =~
               "name=\"twitter:title\" content=\"Add an onboarding checklist - 7 votes - FluxVale\""

      assert html =~ "name=\"description\" content=\"New orgs need a guided first run.\""
      assert html =~ "<h1"
      assert html =~ "2 comments"
    end

    test "the islands SSR into the document (crawlable without JS)", %{conn: conn} do
      post = post!(%{title: "Island SSR probe", description: "x"})
      author = AccountsFixtures.user!()

      Comment.create!(
        %{post_id: post.id, body: "A pre-rendered comment"},
        actor: author
      )

      set_counters!(post, 3, 1)

      html = html_response(get(conn, ~p"/feedback/#{post.slug}"), 200)

      # The vote island's static render carries the count.
      assert html =~ "data-testid=\"vote-island\""
      assert html =~ "3 votes"
      assert html =~ "data-testid=\"vote-sign-in\""
      # The comments island's static render carries the list.
      assert html =~ "data-testid=\"comments-island\""
      assert html =~ "A pre-rendered comment"
      assert html =~ "data-testid=\"comment-sign-in\""
    end

    test "an unknown slug is a real 404", %{conn: conn} do
      conn = get(conn, ~p"/feedback/no-such-request")

      assert response(conn, 404)
    end

    test "a long description truncates the meta description near 160 chars", %{conn: conn} do
      body =
        String.duplicate("word ", 40) <>
          "end of the body text that goes on past the limit for sure and keeps going"

      post = post!(%{title: "Long body request", description: body})

      html = html_response(get(conn, ~p"/feedback/#{post.slug}"), 200)

      [meta] = Regex.run(~r/name="description" content="([^"]*)"/, html, capture: :all_but_first)
      assert String.length(meta) <= 161
      assert String.ends_with?(meta, "…")
      assert String.starts_with?(meta, "word word word")
    end

    test "a meta cut with no word boundary in the head keeps the raw head", %{conn: conn} do
      post = post!(%{title: "Unbroken head request", description: String.duplicate("x", 200)})

      html = html_response(get(conn, ~p"/feedback/#{post.slug}"), 200)

      [meta] = Regex.run(~r/name="description" content="([^"]*)"/, html, capture: :all_but_first)
      assert meta == String.duplicate("x", 160) <> "…"
    end

    test "the description keeps its line breaks", %{conn: conn} do
      post =
        post!(%{
          title: "Multiline request",
          description: "First paragraph.\n\nSecond paragraph after a blank line."
        })

      html = html_response(get(conn, ~p"/feedback/#{post.slug}"), 200)

      assert html =~ "First paragraph.\n\nSecond paragraph after a blank line."
      assert html =~ "whitespace-pre-line"
    end

    test "the status badge carries the status-changed age", %{conn: conn} do
      post = post!(%{title: "Started badge request", description: "x"})
      moved = move_status!(post, :started)

      html = html_response(get(conn, ~p"/feedback/#{moved.slug}"), 200)

      # The label reads "Started ..." — the exact age wording is the
      # helper's contract, covered in FeedbackHTMLTest.
      assert html =~ "Started"
    end

    test "a duplicate renders the merged-into banner linking the original", %{conn: conn} do
      original = post!(%{title: "The canonical export idea", description: "x"})
      dup = post!(%{title: "An export copy", description: "x"})
      moved = move_status!(dup, :duplicate, duplicate_of: original)

      html = html_response(get(conn, ~p"/feedback/#{moved.slug}"), 200)

      assert html =~ "id=\"duplicate-banner\""
      assert html =~ "This request is a duplicate of"
      assert html =~ "The canonical export idea"
      assert html =~ "href=\"/feedback/#{original.slug}\""
    end

    test "a non-canonical host rides noindex (the router plug covers the new routes)", %{
      conn: conn
    } do
      post = post!(%{title: "Noindex probe request", description: "x"})

      conn = get(conn, ~p"/feedback/#{post.slug}")

      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
      assert html_response(conn, 200) =~ ~s(name="robots" content="noindex, nofollow">)
    end
  end

  # #412 T9: the roadmap — a VIEW over the board's post statuses. The
  # page works empty (the shell assertions ride the e2e public-pages
  # spec), so the controller tests focus on membership, ordering, and
  # the head.
  describe "GET /roadmap" do
    test "answers 200 anonymously with the roadmap head", %{conn: conn} do
      conn = get(conn, ~p"/roadmap")
      html = html_response(conn, 200)

      assert conn.status == 200
      assert html =~ "Roadmap · FluxVale</title>"
      assert html =~ ~s(rel="canonical" href="https://fluxvale.com/roadmap")
      assert html =~ ~s(property="og:title" content="Roadmap · FluxVale")
      assert html =~ ~s(name="twitter:card" content="summary_large_image")

      # The :browser pipeline's SeoNoindex plug covers the new route
      # (the test conn's host is not the canonical prod host).
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
      assert html =~ ~s(name="robots" content="noindex, nofollow">)
    end

    test "columns carry exactly the planned, started, completed posts", %{conn: conn} do
      planned = post!(%{title: "Roadmap planned request", description: "x"})
      started = post!(%{title: "Roadmap started request", description: "x"})
      completed = post!(%{title: "Roadmap completed request", description: "x"})
      post!(%{title: "Roadmap open request", description: "x"})
      declined = post!(%{title: "Roadmap declined request", description: "x"})
      original = post!(%{title: "Roadmap original request", description: "x"})
      dup = post!(%{title: "Roadmap duplicate request", description: "x"})

      move_status!(planned, :planned)
      move_status!(started, :started)
      move_status!(completed, :completed)
      move_status!(declined, :declined)
      move_status!(dup, :duplicate, duplicate_of: original)

      html = html_response(get(conn, ~p"/roadmap"), 200)

      for title <- [
            "Roadmap planned request",
            "Roadmap started request",
            "Roadmap completed request"
          ] do
        assert html =~ title
      end

      # Open is the untriaged backlog, declined is the "no", duplicates
      # fold into their originals' presence — none are roadmap states.
      for title <- [
            "Roadmap open request",
            "Roadmap declined request",
            "Roadmap duplicate request"
          ] do
        refute html =~ title
      end
    end

    test "planned orders by votes desc (demand order)", %{conn: conn} do
      low = post!(%{title: "Planned low votes", description: "x"})
      set_counters!(low, 3, 0)
      move_status!(low, :planned)
      high = post!(%{title: "Planned high votes", description: "x"})
      set_counters!(high, 40, 0)
      move_status!(high, :planned)

      html = html_response(get(conn, ~p"/roadmap"), 200)

      assert position(html, "Planned high votes") < position(html, "Planned low votes")
    end

    test "equal votes in planned fall back to the fresher post first", %{conn: conn} do
      first = post!(%{title: "Planned tie first", description: "x"})
      move_status!(first, :planned)
      second = post!(%{title: "Planned tie second", description: "x"})
      move_status!(second, :planned)

      html = html_response(get(conn, ~p"/roadmap"), 200)

      assert position(html, "Planned tie second") < position(html, "Planned tie first")
    end

    test "started orders by the freshest status change", %{conn: conn} do
      old = post!(%{title: "Started long ago", description: "x"})
      fresh = post!(%{title: "Started just now", description: "x"})
      move_status!(old, :started)
      move_status!(fresh, :started)
      # Deterministic pasts (the fixture posture — no action accepts a
      # chosen instant; natural move stamps would order the same way but
      # leave the assertion riding on clock granularity).
      set_status_changed_at!(old, hours_ago(48))
      set_status_changed_at!(fresh, hours_ago(2))

      html = html_response(get(conn, ~p"/roadmap"), 200)

      assert position(html, "Started just now") < position(html, "Started long ago")
    end

    test "completed orders by the freshest status change", %{conn: conn} do
      old = post!(%{title: "Shipped long ago", description: "x"})
      fresh = post!(%{title: "Shipped last week", description: "x"})
      move_status!(old, :completed)
      move_status!(fresh, :completed)
      set_status_changed_at!(old, days_ago(90))
      set_status_changed_at!(fresh, days_ago(6))

      html = html_response(get(conn, ~p"/roadmap"), 200)

      assert position(html, "Shipped last week") < position(html, "Shipped long ago")
    end

    test "items carry their tag chips (display only, the item is one link)", %{conn: conn} do
      platform = tag!(%{name: "Platform", slug: "platform"})
      plain = post!(%{title: "Roadmap plain item", description: "x"})
      tagged = post!(%{title: "Roadmap tagged item", description: "x"})
      tag_post!(tagged, [platform])
      move_status!(plain, :planned)
      move_status!(tagged, :planned)

      html = html_response(get(conn, ~p"/roadmap"), 200)

      assert html =~ "Roadmap tagged item"
      assert html =~ "data-testid=\"feedback-tag\""
      assert html =~ "Platform"

      # The untagged item renders no chip block (its div is guarded).
      assert html =~ "Roadmap plain item"
      assert length(String.split(html, ~s(data-testid="feedback-tag"))) - 1 == 1
    end

    test "a stamp-less started item falls back to its created age in the recency sort", %{
      conn: conn
    } do
      # The coalesce in the recency sort (Started/Completed only —
      # Planned sorts by votes) keeps a stamp-less row from crashing the
      # DateTime compare: the row then orders by its created age. A
      # stamp-less MOVED row is a fixture posture (the seeds force
      # timestamps the actions do not accept), so the probe clears the
      # stamp on a :started post beside stamped ones and asserts the
      # fallback ordering.
      stamped_old = post!(%{title: "Stamped started old", description: "x"})
      stamped_fresh = post!(%{title: "Stamped started fresh", description: "x"})
      move_status!(stamped_old, :started)
      move_status!(stamped_fresh, :started)
      set_status_changed_at!(stamped_old, days_ago(30))
      set_status_changed_at!(stamped_fresh, days_ago(1))

      unstamped = post!(%{title: "Unstamped started newest", description: "x"})
      move_status!(unstamped, :started)
      set_status_changed_at!(unstamped, nil)

      html = html_response(get(conn, ~p"/roadmap"), 200)

      # The unstamped post was created LAST, so under the created-at
      # fallback it sorts ahead of both stamped ones.
      assert position(html, "Unstamped started newest") < position(html, "Stamped started fresh")

      assert position(html, "Stamped started fresh") < position(html, "Stamped started old")
    end

    test "items link their board pages and carry counts and the status age", %{conn: conn} do
      planned = post!(%{title: "Roadmap anatomy request", description: "x"})
      set_counters!(planned, 9, 4)
      move_status!(planned, :planned)
      set_status_changed_at!(planned, days_ago(3))

      html = html_response(get(conn, ~p"/roadmap"), 200)

      assert html =~ "data-testid=\"roadmap-post-#{planned.slug}\""
      assert html =~ "href=\"/feedback/#{planned.slug}\""
      assert html =~ "9 votes"
      assert html =~ "4 comments"
      # The status-changed relative date rides the board's helper.
      assert html =~ "Planned 3 days ago"
    end

    test "an empty roadmap reads each column's honest copy", %{conn: conn} do
      html = html_response(get(conn, ~p"/roadmap"), 200)

      assert html =~ "Nothing planned yet."
      assert html =~ "Nothing underway yet."
      assert html =~ "Nothing shipped yet."
      refute html =~ "data-testid=\"roadmap-post-"

      # The chrome and the tabs stay.
      assert html =~ "data-testid=\"footer-feedback\""
      assert html =~ "data-testid=\"roadmap-link\""
    end

    test "the board and roadmap cross-link both directions", %{conn: conn} do
      board = html_response(get(conn, ~p"/feedback"), 200)
      roadmap = html_response(get(conn, ~p"/roadmap"), 200)

      # The tab pair rides both pages: the board links here, the
      # roadmap links back.
      assert board =~ "data-testid=\"roadmap-link\""
      assert board =~ ~s(href="/roadmap")
      assert roadmap =~ ~s(href="/feedback")

      # The roadmap page has exactly one aria-current source (its lane
      # tab — no sort tabs or chips there), so the marking belongs to
      # the roadmap view.
      assert roadmap =~ ~s(aria-current="page")
      assert length(String.split(roadmap, ~s(aria-current="page"))) - 1 == 1
    end
  end

  defp hours_ago(hours), do: DateTime.add(DateTime.utc_now(), -hours * 3_600, :second)

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

  describe "the tag filter (T10)" do
    test "the board renders the tags in use as filter chips", %{conn: conn} do
      platform = tag!(%{name: "Platform", slug: "platform"})
      post = post!(%{title: "Chip set request", description: "x"})
      tag_post!(post, [platform])

      html = html_response(get(conn, ~p"/feedback"), 200)

      assert html =~ "data-testid=\"feedback-tag-chip-platform\""
      assert html =~ "Platform"
    end

    test "a tag with no pairings renders no chip", %{conn: conn} do
      tag!(%{name: "Unused tag", slug: "unused-tag"})
      post!(%{title: "Untagged chip request", description: "x"})

      html = html_response(get(conn, ~p"/feedback"), 200)

      refute html =~ "unused-tag"
    end

    test "?tag=slug narrows the board to posts carrying the tag", %{conn: conn} do
      platform = tag!(%{name: "Platform", slug: "platform"})
      tagged = post!(%{title: "Carries the tag", description: "x"})
      tag_post!(tagged, [platform])
      post!(%{title: "Carries nothing", description: "x"})

      html = html_response(get(conn, ~p"/feedback?tag=platform"), 200)

      assert html =~ "Carries the tag"
      refute html =~ "Carries nothing"
    end

    test "an unknown tag slug falls back to the unfiltered board", %{conn: conn} do
      post!(%{title: "Unknown tag tagged", description: "x"})
      post!(%{title: "Unknown tag plain", description: "x"})

      html = html_response(get(conn, ~p"/feedback?tag=bogus-slug"), 200)

      assert html =~ "Unknown tag tagged"
      assert html =~ "Unknown tag plain"
    end

    test "the tag filter combines with the status filter", %{conn: conn} do
      platform = tag!(%{name: "Platform", slug: "platform"})

      planned = post!(%{title: "Planned and tagged", description: "x"})
      tag_post!(planned, [platform])
      move_status!(planned, :planned)

      open = post!(%{title: "Open and tagged", description: "x"})
      tag_post!(open, [platform])

      html = html_response(get(conn, ~p"/feedback?tag=platform&status=planned"), 200)

      assert html =~ "Planned and tagged"
      refute html =~ "Open and tagged"
    end

    test "a tag filter that matches nothing reads the tag empty state", %{conn: conn} do
      # The vocabulary row exists but no post carries it — the honest
      # sentence is the filtered one, not "No posts yet."
      tag!(%{name: "Empty tag", slug: "empty-tag"})

      html = html_response(get(conn, ~p"/feedback?tag=empty-tag"), 200)

      assert html =~ "No posts with this tag yet."
    end

    test "the board rows show their tag chips", %{conn: conn} do
      platform = tag!(%{name: "Platform", slug: "platform"})
      tagged = post!(%{title: "Row chips request", description: "x"})
      tag_post!(tagged, [platform])

      html = html_response(get(conn, ~p"/feedback"), 200)

      assert html =~ "Row chips request"
      assert html =~ "data-testid=\"feedback-tag\""
    end

    test "an active tag survives a sort flip", %{conn: conn} do
      platform = tag!(%{name: "Platform", slug: "platform"})
      tagged = post!(%{title: "Sort survival request", description: "x"})
      tag_post!(tagged, [platform])

      html = html_response(get(conn, ~p"/feedback?tag=platform"), 200)

      # The sort tabs keep the filter (sort first, then the tag, in the
      # stable param order — rendered HTML escapes the ampersand).
      assert html =~ "href=\"/feedback?sort=new&amp;tag=platform\""
      assert html =~ "href=\"/feedback?tag=platform\""
    end

    test "an active tag survives a status chip", %{conn: conn} do
      platform = tag!(%{name: "Platform", slug: "platform"})
      tagged = post!(%{title: "Status survival request", description: "x"})
      tag_post!(tagged, [platform])

      html = html_response(get(conn, ~p"/feedback?tag=platform"), 200)

      # The All chip and each status chip keep the filter (the default
      # sort collapses out of the query).
      assert html =~ "href=\"/feedback?tag=platform\""
      assert html =~ "href=\"/feedback?status=open&amp;tag=platform\""
    end

    test "an active tag survives the pager — page two stays filtered", %{conn: conn} do
      platform = tag!(%{name: "Platform", slug: "platform"})

      for n <- 1..21 do
        tagged =
          post!(%{title: "Paged tag request #{String.pad_leading(Integer.to_string(n), 3, "0")}"})

        tag_post!(tagged, [platform])
      end

      untagged = post!(%{title: "Paged untagged request", description: "x"})

      page_one = html_response(get(conn, ~p"/feedback?tag=platform"), 200)
      assert page_one =~ "Page 1 of 2"
      assert page_one =~ "href=\"/feedback?tag=platform&amp;page=2\""
      refute page_one =~ "Paged untagged request"

      # And the link's destination is still the filtered view.
      page_two = html_response(get(conn, ~p"/feedback?tag=platform&page=2"), 200)
      assert page_two =~ "Paged tag request 001"
      refute page_two =~ "Paged untagged request"

      assert html_response(get(conn, ~p"/feedback/#{untagged.slug}"), 200) =~
               "Paged untagged request"
    end

    test "a huge page still clamps with the tag filter applied", %{conn: conn} do
      platform = tag!(%{name: "Platform", slug: "platform"})
      tagged = post!(%{title: "Clamp with tag", description: "x"})
      tag_post!(tagged, [platform])

      html = html_response(get(conn, "/feedback?tag=platform&page=99999999999999999999"), 200)

      assert html =~ "No posts with this tag yet."
      refute html =~ "Clamp with tag"
    end
  end

  describe "post page tag chips and the catalog cross-link (T10)" do
    test "the post page renders its tag chips linking the filtered board", %{conn: conn} do
      kavita = tag!(%{name: "Kavita", slug: "kavita"})
      post = post!(%{title: "Chip page request", description: "x"})
      tag_post!(post, [kavita])

      html = html_response(get(conn, ~p"/feedback/#{post.slug}"), 200)

      assert html =~ "data-testid=\"post-tags\""
      assert html =~ "data-testid=\"feedback-tag-link\""
      assert html =~ "href=\"/feedback?tag=kavita\""
    end

    test "a tag whose slug matches a catalog app renders the /apps cross-link", %{conn: conn} do
      catalog_app!("kavita")
      kavita = tag!(%{name: "Kavita", slug: "kavita"})
      post = post!(%{title: "Cross-link request", description: "x"})
      tag_post!(post, [kavita])

      html = html_response(get(conn, ~p"/feedback/#{post.slug}"), 200)

      assert html =~ "data-testid=\"feedback-app-link\""
      assert html =~ "href=\"/apps/kavita\""
      assert html =~ "Kavita in the app catalog"
    end

    test "a tag with no catalog match renders no cross-link", %{conn: conn} do
      platform = tag!(%{name: "Platform", slug: "platform"})
      post = post!(%{title: "No cross-link request", description: "x"})
      tag_post!(post, [platform])

      html = html_response(get(conn, ~p"/feedback/#{post.slug}"), 200)

      assert html =~ "Platform"
      refute html =~ "data-testid=\"feedback-app-link\""
    end

    test "an untagged post renders no chips at all", %{conn: conn} do
      post = post!(%{title: "Bare post request", description: "x"})

      html = html_response(get(conn, ~p"/feedback/#{post.slug}"), 200)

      refute html =~ "data-testid=\"post-tags\""
      refute html =~ "data-testid=\"feedback-tag-link\""
    end
  end
end
