defmodule FluxVale.Feedback.Operations.SimilarPosts do
  @moduledoc """
  The composer's similar-posts nudge (fluxvale/fluxvale#412, T5,
  [ADR-0026](../../../../../../../docs/adr/00026-feedback-board.md)): the posts
  that look like what the visitor is typing, so dupes fold into their
  originals instead of splitting votes.

  The title normalizes to significant tokens (downcase, punctuation to
  spaces, stop words dropped, 4+ graphemes kept) and the read pulls
  every open/planned/started post whose title ILIKE-matches ANY token —
  the shared-token count then ranks in memory, because Postgres would
  need a tsvector per token set to rank server-side and the board is
  small this slice. Revisit trigger: a board big enough that the in
  -memory rank reads more than a page of rows moves the count into the
  query (a computed ILIKE score or a tsvector column).

  Only unresolved statuses surface — completed/declined work and folded
  duplicates are not a "maybe don't post this" answer. Reads ride the
  public read policy (`actor: nil`, the FeedbackController posture).
  """

  alias FluxVale.Feedback.Post

  require Ash.Expr
  require Ash.Query

  # Common words that never make a title similar on their own. Owned
  # outright (the operations rule): a word lands here only if dropping
  # it cannot change which posts share meaning.
  @stop_words ~w(this that with from have has had was were been being
    will would could should what when where which there here into over
    under about just also some then than them they their please make
    need want doesn dont cannot cant after before while when more most
    very much many such only same even still again each other your you
    are isnt arent dont doesnt didnt)

  @min_token_length 4
  @min_shared_tokens 2
  @limit 3

  # The statuses a still-live request can carry — the query's filter.
  @live_statuses [:open, :planned, :started]

  @spec call(String.t(), keyword()) :: [Post.t()]
  def call(title, _opts \\ [])

  def call(title, _opts) when is_binary(title) do
    case significant_tokens(title) do
      [] ->
        []

      tokens ->
        tokens
        |> live_posts_matching_any()
        |> rank_by_shared(tokens)
        |> Enum.take(@limit)
    end
  end

  # A non-binary title (a crafted param AshPhoenix decoded to a map,
  # say) has no tokens: silence, like an empty title.
  def call(_title, _opts), do: []

  @doc """
  The title's significant tokens — downcased, punctuation split out,
  stop words and sub-4-grapheme fragments dropped. Public for the unit
  suite (the token shapes are the ranking's contract).
  """
  @spec significant_tokens(String.t()) :: [String.t()]
  def significant_tokens(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.reject(fn token ->
      stop_word?(token) or String.length(token) < @min_token_length
    end)
  end

  defp stop_word?(token), do: token in @stop_words

  # One ILIKE arm per token, ORed — the fetch is deliberately wide (any
  # token); the shared count below is what decides. The keyword filter
  # form keeps the arm building runtime-shaped (no expr composition).
  defp live_posts_matching_any(tokens) do
    or_arms = Enum.map(tokens, fn token -> [title: [ilike: "%#{token}%"]] end)

    Post
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(status in ^@live_statuses)
    |> Ash.Query.filter(or: or_arms)
    |> Ash.read!(actor: nil)
  end

  # Posts sharing at least @min_shared_tokens tokens, best first: the
  # shared count wins, the vote count breaks ties (the board's own
  # sort), age breaks those (fresher first). Stable sorts, primary key
  # last.
  defp rank_by_shared(posts, tokens) do
    ranked =
      posts
      |> Enum.map(fn post -> {post, shared_count(post, tokens)} end)
      |> Enum.filter(fn {_post, shared} -> shared >= @min_shared_tokens end)

    ranked
    |> Enum.sort_by(fn {post, _shared} -> post.created_at end, {:desc, DateTime})
    |> Enum.sort_by(fn {post, _shared} -> post.vote_count end, :desc)
    |> Enum.sort_by(fn {_post, shared} -> shared end, :desc)
    |> Enum.map(fn {post, _shared} -> post end)
  end

  defp shared_count(post, tokens) do
    title = significant_tokens(post.title)
    title_tokens = MapSet.new(title)

    Enum.count(tokens, &MapSet.member?(title_tokens, &1))
  end
end
