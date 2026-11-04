defmodule FluxVale.Feedback.Post.AuthorStatusMail do
  @moduledoc """
  The author-notification slice of the status workflow
  (fluxvale/fluxvale#412 T7): when a post's status actually moves, its
  author gets the plain-text mail (`Mailer.deliver_feedback_status_changed`).

  The hook rides `after_transaction` and fires ONLY on the committed
  `{:ok, _}` result — the mail reports a write that happened, never one
  still in flight or rolled back. The network round-trip then runs OUT
  of the write transaction: an `after_action` hook would hold the
  feedback_posts row lock across the Postmark call, and a failed commit
  would leave the author mailed about a change that never became
  durable. One mail per transition is inherited, not re-derived —
  `:set_status` is the only status-moving action (the `TopupOutcomeMail`
  once-from-one-caller shape).

  The `TopupOutcomeMail` discipline: delivery failure logs and never fails
  the action — the status change already happened, the board state owns
  the truth. The author's address is resolved authorize-free (the
  `AuthorUsername` stance — notifying the author is the mailer's job, not
  an authorization question) and an unresolvable one (a system row with
  no author, an account without its mirror row) is an info-log skip, not
  an error.

  Scope note on the fresh-transition gate: it compares `post.status` to
  `changeset.data.status`, which is the CALLER's record — a stale admin
  tab can produce a phantom mail or a silent skip on a DB-level
  transition. Single-admin moderation makes that unlikely, and Post
  carries no optimistic lock; no re-read is added, the comparison stays
  the caller's honest before/after.
  """

  use Ash.Resource.Change

  alias FluxVale.Feedback.Post
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Mailer

  require Logger

  # Ash.Query.filter is a macro
  require Ash.Query

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &notify_author/2)
  end

  # The fresh-transition gate: re-asserting the current status must not
  # mail. changeset.data carries the caller's pre-write record, so the
  # before/after comparison IS the audit fact (SetStatus stamps it; here
  # we read it). The {:error, _} arm passes refused moves through
  # untouched — nothing to notify about.
  defp notify_author(changeset, {:ok, post} = result) do
    if post.status != changeset.data.status do
      deliver(post)
    end

    result
  end

  defp notify_author(_changeset, result), do: result

  defp deliver(post) do
    post
    |> author_address()
    |> deliver_to(post)
  end

  defp deliver_to({:ok, address}, post) do
    case Mailer.deliver_feedback_status_changed(address, post.status, post.title, post.slug) do
      {:ok, _delivery} -> :ok
      {:error, reason} -> log_failure(post, reason)
    end
  end

  defp deliver_to(:none, post) do
    Logger.info("Feedback post #{post.id} (#{post.status}) has no mailable author address")

    :ok
  end

  # The account's verified primary — the address every user-visible
  # surface displays (the User.primary_email definition), queried
  # directly by the FK the post already carries (the OwnerSignIn posture).
  defp author_address(%Post{created_by_user_id: nil}), do: :none

  defp author_address(post) do
    case UserEmail
         |> Ash.Query.filter(
           user_id == ^post.created_by_user_id and is_primary and not is_nil(verified_at)
         )
         |> Ash.read_one(authorize?: false) do
      {:ok, %{address: address}} ->
        {:ok, to_string(address)}

      {:ok, nil} ->
        :none

      # coveralls-ignore-start - defensive: a DB read failure mid-hook,
      # not simulatable under the sandbox — skip, never fail the action
      {:error, _reason} ->
        :none

        # coveralls-ignore-stop
    end
  end

  defp log_failure(post, reason) do
    Logger.error(
      "Feedback post #{post.id} (#{post.status}) author mail failed: #{inspect(reason)}"
    )

    :ok
  end

  @impl Ash.Resource.Change
  def atomic?, do: false
end
