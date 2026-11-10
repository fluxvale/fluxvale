defmodule FluxVale.Feedback.Comment.BumpPostCounter do
  @moduledoc """
  Maintains `Post.comment_count` ([ADR-0026](../../../../../../../../../docs/adr/00026-feedback-board.md)
  §1's cached aggregate): +1 as the comment lands, -1 when moderation
  removes it.

  The bump rides Post's dedicated `:bump_comment_count` action — a
  paper-trail-ignored write (`ignore_actions`, ADR-0048: the counter is
  derivative data), so comment activity moves `post.updated_at` (the
  board's sitemap `lastmod` reads it — ADR-0026 §4, ADR-0025, pinned by
  a test) without spamming the post's trail. Any update touches the
  timestamp; the observable activity-updated semantics are unchanged.
  A slice that wants a quieter `updated_at` for the board must change
  the semantics for BOTH counters in the open, not "fix" this side
  silently.

  Race safety is the SQL shape, not locking discipline: the bump is
  `comment_count = comment_count + N` (an atomic Ash expression), so two
  concurrent comments on one post serialize on the row lock and neither
  increment is lost. It runs `before_action` — inside the comment
  action's transaction, so a refused comment rolls the bump back with it
  (the SetStatus mechanics).

  The post is read fresh inside that transaction with `authorize?:
  false` — an invariant write, the action's own policy already gated the
  caller (the SetStatus stance). A missing post fails the comment
  field-scoped before the FK could answer with an Ecto constraint crash.
  """

  use Ash.Resource.Change

  alias FluxVale.Feedback.Post

  @impl Ash.Resource.Change
  def change(changeset, opts, _context) do
    delta = Keyword.fetch!(opts, :by)

    Ash.Changeset.before_action(changeset, fn changeset ->
      bump(changeset, delta)
    end)
  end

  defp bump(changeset, delta) do
    post_id = Ash.Changeset.get_attribute(changeset, :post_id)

    case Ash.get(Post, post_id, authorize?: false) do
      {:ok, post} ->
        post
        |> Ash.Changeset.for_update(:bump_comment_count, %{}, authorize?: false)
        |> Ash.Changeset.atomic_update(:comment_count, Ash.Expr.expr(comment_count + ^delta))
        |> Ash.update!(authorize?: false)

        changeset

      # Dangling id or unreadable row — refuse loudly either way; the
      # FK answers the dangling case at the DB as the race backstop.
      {:error, _reason} ->
        Ash.Changeset.add_error(
          changeset,
          field: :post_id,
          message: "must reference an existing post"
        )
    end
  end

  @impl Ash.Resource.Change
  def atomic?, do: false
end
