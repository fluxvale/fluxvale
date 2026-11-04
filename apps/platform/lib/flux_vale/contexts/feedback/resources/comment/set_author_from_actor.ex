defmodule FluxVale.Feedback.Comment.SetAuthorFromActor do
  @moduledoc """
  The comment's author IS the actor — never accepted input. Mirrors
  `Post.SetActorDefaults`' eager pattern: `author_user_id` is set before
  validations run, so any later required-field pass sees it.

  Where the anonymous refusal actually lands here: **Forbidden** from the
  `actor_present()` policy. Ash 3's create pipeline (verified against the
  vendored 3.32.3 source) builds the changeset with require-values drawn
  from the ACCEPT list only (`Ash.Resource.Transformers.CacheActionInputs`),
  and `author_user_id` is not in `accept([:post_id, :body])` — so the
  changeset reaches `authorize` (Create.ex's `with` chain, before
  `with_hooks`) still valid, and the policy is the first and total answer.
  The deeper require-values passes that do check `author_user_id`
  (including the belongs_to pass) run post-authorization, inside commit.

  This deliberately differs from Post's anonymous shape: Post answers
  field-scoped only because it carries an explicit
  `validate(present(:organization_id))`, which runs pre-policy. Comment
  has no twin of that validation — a refused anonymous comment is the
  gate's Forbidden, not a field error. Either way nothing is written.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, %{actor: actor} = _context) when not is_nil(actor) do
    Ash.Changeset.force_change_attribute(changeset, :author_user_id, actor.id)
  end

  def change(changeset, _opts, _context) do
    # No actor: the changeset stays valid and the actor_present() policy
    # answers Forbidden (see the moduledoc for the pipeline order).
    changeset
  end

  @impl Ash.Resource.Change
  def atomic?, do: false
end
