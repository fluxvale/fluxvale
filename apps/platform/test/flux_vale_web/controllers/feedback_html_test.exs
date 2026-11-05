defmodule FluxValeWeb.FeedbackHTMLTest do
  @moduledoc false

  # Pure display helpers — no DB, no conn.

  use ExUnit.Case, async: true

  alias FluxVale.Feedback.Post
  alias FluxValeWeb.FeedbackHTML

  describe "time_ago/1" do
    test "a fresh timestamp reads as just now" do
      fresh = DateTime.add(DateTime.utc_now(), -30, :second)

      assert FeedbackHTML.time_ago(fresh) == "just now"
    end

    test "clock skew (a future timestamp) reads as just now too" do
      future = DateTime.add(DateTime.utc_now(), 120, :second)

      assert FeedbackHTML.time_ago(future) == "just now"
    end

    test "minutes" do
      one_minute = DateTime.add(DateTime.utc_now(), -60, :second)
      two_minutes = DateTime.add(DateTime.utc_now(), -150, :second)

      assert FeedbackHTML.time_ago(one_minute) == "1 minute ago"
      assert FeedbackHTML.time_ago(two_minutes) == "2 minutes ago"
    end

    test "hours" do
      one_hour = DateTime.add(DateTime.utc_now(), -3_600, :second)
      two_hours = DateTime.add(DateTime.utc_now(), -7_200, :second)

      assert FeedbackHTML.time_ago(one_hour) == "1 hour ago"
      assert FeedbackHTML.time_ago(two_hours) == "2 hours ago"
    end

    test "days" do
      one_day = DateTime.add(DateTime.utc_now(), -86_400, :second)
      three_days = DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)

      assert FeedbackHTML.time_ago(one_day) == "1 day ago"
      assert FeedbackHTML.time_ago(three_days) == "3 days ago"
    end

    test "weeks" do
      one_week = DateTime.add(DateTime.utc_now(), -604_800, :second)
      ten_days = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)
      fifteen_days = DateTime.add(DateTime.utc_now(), -15 * 86_400, :second)

      assert FeedbackHTML.time_ago(one_week) == "1 week ago"
      assert FeedbackHTML.time_ago(ten_days) == "1 week ago"
      assert FeedbackHTML.time_ago(fifteen_days) == "2 weeks ago"
    end

    test "months" do
      one_month = DateTime.add(DateTime.utc_now(), -2_629_800, :second)
      forty_days = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
      hundred_days = DateTime.add(DateTime.utc_now(), -100 * 86_400, :second)

      assert FeedbackHTML.time_ago(one_month) == "1 month ago"
      assert FeedbackHTML.time_ago(forty_days) == "1 month ago"
      assert FeedbackHTML.time_ago(hundred_days) == "3 months ago"
    end

    test "years" do
      one_year = DateTime.add(DateTime.utc_now(), -31_557_600, :second)
      two_years = DateTime.add(DateTime.utc_now(), -800 * 86_400, :second)

      assert FeedbackHTML.time_ago(one_year) == "1 year ago"
      assert FeedbackHTML.time_ago(two_years) == "2 years ago"
    end
  end

  describe "status_changed_label/1" do
    test "a moved post reads the status label plus its age" do
      post = %{
        status: :started,
        status_changed_at: DateTime.add(DateTime.utc_now(), -2 * 86_400, :second),
        created_at: DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
      }

      assert FeedbackHTML.status_changed_label(post) == "Started 2 days ago"
    end

    test "a post that never moved reads as the posted age" do
      post = %{
        status: :open,
        status_changed_at: nil,
        created_at: DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)
      }

      assert FeedbackHTML.status_changed_label(post) == "Posted 3 days ago"
    end
  end

  test "the count helpers singularize exactly at one" do
    assert FeedbackHTML.votes_label(1) == "1 vote"
    assert FeedbackHTML.votes_label(3) == "3 votes"
    assert FeedbackHTML.comments_label(0) == "0 comments"
    assert FeedbackHTML.comments_label(2) == "2 comments"
  end

  test "status labels and tones cover every status the resource declares" do
    # The iteration source is the RESOURCE's declared list, not this
    # module's own: adding a status to the resource without a label and
    # tone fails here, instead of 500ing the public board at render
    # (Map.fetch! is the loud renderer by design).
    for status <- Post.status_values() do
      assert is_binary(FeedbackHTML.status_label(status))
      assert is_binary(FeedbackHTML.status_tone(status))
    end
  end

  describe "empty_title/2" do
    test "the unfiltered board reads No posts yet" do
      assert FeedbackHTML.empty_title(nil, nil) == "No posts yet."
    end

    test "a zero-match status filter keeps the status copy" do
      for status <- Post.status_values() do
        assert FeedbackHTML.empty_title(status, nil) == "No posts with this status yet."
      end
    end

    test "a tag filter names the tag, alone or combined" do
      assert FeedbackHTML.empty_title(nil, :tag) == "No posts with this tag yet."
      assert FeedbackHTML.empty_title(:open, :tag) == "No posts with this tag yet."
    end
  end

  describe "board_href/4" do
    test "defaults collapse to the bare board URL" do
      assert FeedbackHTML.board_href("top", nil, 1, nil) == "/feedback"
    end

    test "a non-default sort rides the query" do
      assert FeedbackHTML.board_href("new", nil, 1, nil) == "/feedback?sort=new"
    end

    test "a status filter rides the query" do
      assert FeedbackHTML.board_href("top", :planned, 1, nil) == "/feedback?status=planned"
    end

    test "page two rides the query" do
      assert FeedbackHTML.board_href("top", nil, 2, nil) == "/feedback?page=2"
    end

    test "a tag rides the query" do
      assert FeedbackHTML.board_href("top", nil, 1, "kavita") == "/feedback?tag=kavita"
    end

    test "the full view state keeps the stable param order (sort, status, tag, page)" do
      assert FeedbackHTML.board_href("new", :open, 2, "kavita") ==
               "/feedback?sort=new&status=open&tag=kavita&page=2"
    end

    test "the 3-arity default still collapses to the bare URL" do
      assert FeedbackHTML.board_href("top", nil, 1) == "/feedback"
    end
  end

  describe "app_linked_tags/2" do
    @kavita %FluxVale.Feedback.Tag{slug: "kavita", name: "Kavita"}
    @platform %FluxVale.Feedback.Tag{slug: "platform", name: "Platform"}

    test "keeps only the tags whose slug matches a catalog app" do
      app_slugs = MapSet.new(["kavita"])

      assert FeedbackHTML.app_linked_tags([@kavita, @platform], app_slugs) == [@kavita]
    end

    test "an empty catalog set links nothing" do
      assert FeedbackHTML.app_linked_tags([@kavita], MapSet.new()) == []
    end
  end

  describe "tag_chip_active?/2" do
    @chip %FluxVale.Feedback.Tag{slug: "kavita", name: "Kavita"}

    test "no active tag means no chip is active" do
      refute FeedbackHTML.tag_chip_active?(@chip, nil)
    end

    test "the chip matching the filter is active" do
      assert FeedbackHTML.tag_chip_active?(@chip, @chip)
      refute FeedbackHTML.tag_chip_active?(@chip, %FluxVale.Feedback.Tag{slug: "other"})
    end
  end

  # #412 T9: the roadmap's display contract.
  describe "roadmap helpers" do
    test "column labels cover the three roadmap statuses" do
      assert FeedbackHTML.roadmap_column_label(:planned) == "Planned"
      assert FeedbackHTML.roadmap_column_label(:started) == "Started"
      assert FeedbackHTML.roadmap_column_label(:completed) == "Completed"
    end

    test "empty-column copy is one honest sentence per column" do
      assert FeedbackHTML.empty_column_copy(:planned) == "Nothing planned yet."
      assert FeedbackHTML.empty_column_copy(:started) == "Nothing underway yet."
      assert FeedbackHTML.empty_column_copy(:completed) == "Nothing shipped yet."
    end
  end
end
