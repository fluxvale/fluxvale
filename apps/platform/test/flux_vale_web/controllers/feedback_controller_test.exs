defmodule FluxValeWeb.FeedbackControllerTest do
  @moduledoc false

  # async: true — pure sandbox DB reads, no global state (the blog's
  # persistent_term posture does not apply here).

  use FluxValeWeb.ConnCase, async: true

  import FluxVale.TestSupport.FeedbackFixtures

  defp position(html, needle) do
    assert html =~ needle

    {pos, _len} = :binary.match(html, needle)
    pos
  end

  defp row_count(html) do
    segments = String.split(html, ~s(data-testid="feedback-post-))
    length(segments) - 1
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

    test "a column item with no status stamp still renders, ordered by age", %{conn: conn} do
      # The coalesce in the recency sort keeps a stamp-less row from
      # crashing the DateTime compare (the seeds force timestamps the
      # actions do not accept, so a stamp-less moved row is a fixture
      # posture, not an action state).
      post = post!(%{title: "Unstamped planned request", description: "x"})
      move_status!(post, :planned)
      set_status_changed_at!(post, nil)

      html = html_response(get(conn, ~p"/roadmap"), 200)

      assert html =~ "Unstamped planned request"
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
end
