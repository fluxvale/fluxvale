defmodule FluxVale.Feedback.Operations.SimilarPostsTest do
  @moduledoc """
  The composer's similar-posts nudge (#412 T5): the token shapes, the
  ranking, and the exclusions are the contract the LiveView renders.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Feedback
  alias FluxVale.Feedback.Operations.SimilarPosts
  alias FluxVale.Feedback.Post
  alias FluxVale.TestSupport.FeedbackFixtures
  # Fixture titles need distinct vocabularies per test, so the post!
  # wrapper keeps the shape but takes the title verbatim.
  defp post!(title), do: FeedbackFixtures.post!(%{title: title})

  # --- Token shapes -------------------------------------------------------------

  describe "significant_tokens/1" do
    test "downcases and strips punctuation" do
      assert SimilarPosts.significant_tokens("Dark-Mode: Toggle!!! (Settings Page)") ==
               ["dark", "mode", "toggle", "settings", "page"]
    end

    test "drops stop words" do
      # Every word here is either a stop word or under 4 graphemes.
      assert SimilarPosts.significant_tokens("This is a bug in the app that we fix") == []
    end

    test "keeps only 4+ grapheme tokens" do
      assert SimilarPosts.significant_tokens("Add SSH key upload UX flow") ==
               ["upload", "flow"]
    end

    test "an empty or blank title has no tokens" do
      assert SimilarPosts.significant_tokens("") == []
      assert SimilarPosts.significant_tokens("   ") == []
    end
  end

  # --- The nudge ------------------------------------------------------------------

  describe "call/2" do
    test "finds live posts sharing 2+ tokens with the typed title" do
      post!("Add dark mode toggle for settings page")

      assert [%Post{} = found] = Feedback.similar_posts("please add dark mode support")

      assert found.title == "Add dark mode toggle for settings page"
    end

    test "posts sharing one token are excluded" do
      post!("Add dark mode toggle for settings page")

      # "dark" alone: one shared token, under the 2+ bar.
      assert [] = Feedback.similar_posts("dark corner of the landing screen")
    end

    test "a title with fewer than two significant tokens searches nothing" do
      post!("Add dark mode toggle for settings page")

      assert [] = Feedback.similar_posts("the this that with")
      assert [] = Feedback.similar_posts("")
      assert [] = Feedback.similar_posts("fix it")
    end

    test "a non-binary title is silence (the crafted-param shape)" do
      assert [] = Feedback.similar_posts(%{"garbage" => "input"})
    end

    test "the operation answers the domain's delegate call shape" do
      post!("Add dark mode toggle for settings")

      # The domain delegates as call/2; the unit suite rides the same
      # entrypoint directly once so the head is covered off the seam,
      # and the default-opts arity rides the generated wrapper.
      assert [%Post{}] = SimilarPosts.call("dark mode settings page", [])
      assert [%Post{}] = SimilarPosts.call("dark mode settings page")
    end

    test "rank: more shared tokens win" do
      post!("Add dark mode toggle to the settings page")
      post!("Add dark mode everywhere in the app")

      # Both share "dark mode"; the first shares "settings" too.
      assert [%{title: first}, _second] = Feedback.similar_posts("dark mode settings")
      assert first == "Add dark mode toggle to the settings page"
    end

    test "rank: equal shares go to more votes" do
      low = post!("Add dark mode toggle please now")
      high = post!("Add dark mode switch right away")
      FeedbackFixtures.set_counters!(low, 1, 0)
      FeedbackFixtures.set_counters!(high, 9, 0)

      assert [%{title: "Add dark mode switch right away"}, _low] =
               Feedback.similar_posts("dark mode control")
    end

    test "completed, declined, and duplicate posts never surface" do
      # The live control matches the search and is the only row that
      # may surface; the gated-out rows match it too (ILIKE-wise) and
      # must not.
      control = post!("Add dark mode toggle to the sidebar screen")

      completed = post!("Add dark mode toggle to the profile screen")
      FeedbackFixtures.move_status!(completed, :completed)

      declined = post!("Add dark mode toggle to the toolbar screen")
      FeedbackFixtures.move_status!(declined, :declined)

      original = post!("Something entirely different worth folding")
      dup = post!("Add dark mode toggle to the footer screen someday")
      FeedbackFixtures.move_status!(dup, :duplicate, duplicate_of: original)

      assert [%Post{} = found] = Feedback.similar_posts("dark mode profile")
      assert found.id == control.id
    end

    test "at most three posts surface, best first" do
      for suffix <- ["alpha", "beta", "gamma", "delta"] do
        post!("Add dark mode toggle for the #{suffix} view")
      end

      results = Feedback.similar_posts("dark mode toggle view")

      assert length(results) == 3
      # All four share the same tokens, so the fresher rows win the caps
      # and the oldest (alpha) falls off.
      refute Enum.any?(results, &(&1.title =~ "alpha"))
    end
  end
end
