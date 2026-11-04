defmodule FluxVale.Feedback.Vote.BumpPostVoteCount do
  @moduledoc """
  The cached counter's maintenance (ADR-0026 §1): the board reads
  `Post.vote_count`, never a live count, so cast and retract keep the
  column true. The increment is ATOMIC — `vote_count = vote_count ± 1`
  evaluated in SQL, not a read-modify-write — so concurrent casts on a
  post cannot lose one. Runs before_action inside the cast/retract
  transaction: the bump and the vote row land or roll back as one unit.

  A post that cannot resolve (a dangling `post_id`) fails the write
  loudly and field-scoped — the same fail-closed answer SetStatus gives
  a dangling duplicate target; the FK is the DB backstop.
  """

  use Ash.Resource.Change

  alias FluxVale.Feedback.Post

  require Ash.Expr

  @impl Ash.Resource.Change
  def change(changeset, opts, _context) do
    step = Keyword.fetch!(opts, :by)

    Ash.Changeset.before_action(changeset, fn changeset ->
      maintain_count(changeset, step)
    end)
  end

  defp maintain_count(changeset, step) do
    case resolve_post(changeset) do
      {:ok, post} ->
        bump(post, step)
        changeset

      # Dangling id or missing attribute — refuse loudly (nothing
      # written); the FK answers the dangling case at the DB as the race
      # backstop.
      {:error, _reason} ->
        missing_post(changeset)
    end
  end

  defp resolve_post(changeset) do
    case Ash.Changeset.get_attribute(changeset, :post_id) do
      # coveralls-ignore-start - unreachable through the actions: :cast
      # answers an absent post_id with the belongs_to Required error at
      # changeset build (before before_action hooks run), and :retract's
      # row carries a NOT NULL post_id. Defensive totality only.
      nil ->
        {:error, :missing_post_id}

      # coveralls-ignore-stop
      post_id ->
        Ash.get(Post, post_id, authorize?: false)
    end
  end

  # authorize?: false — internal invariant maintenance; the vote
  # action's policy already gated the caller (the SetPrimary stance).
  # The only change is the atomic, so the UPDATE is one SQL expression.
  defp bump(post, step) do
    post
    |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
    |> Ash.Changeset.atomic_update(:vote_count, Ash.Expr.expr(vote_count + ^step))
    |> Ash.update!(authorize?: false)
  end

  defp missing_post(changeset) do
    Ash.Changeset.add_error(
      changeset,
      field: :post_id,
      message: "must reference an existing post"
    )
  end

  @impl Ash.Resource.Change
  def atomic?, do: false
end
