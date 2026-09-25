defmodule FluxVale.Infrastructure.Instance.SetUserFromActor do
  @moduledoc """
  Sets `user_id` from the action's actor on create — instances are born
  owned (the #74 deploy flow is the user-facing path; policies scope
  read/update/destroy to that owner).
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, %{actor: actor}) when not is_nil(actor) do
    Ash.Changeset.force_change_attribute(changeset, :user_id, actor.id)
  end

  def change(changeset, _opts, _context) do
    # No actor: the `present(:user_id)` create validation reports it with
    # a field-scoped message instead of an actor-shaped crash here.
    changeset
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (writes another row)
  def atomic?, do: false
end
