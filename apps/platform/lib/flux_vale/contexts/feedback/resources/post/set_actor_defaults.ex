defmodule FluxVale.Feedback.Post.SetActorDefaults do
  @moduledoc """
  Posts are born of the actor: `created_by_user_id` is the actor and
  `organization_id` their personal org — the ownership + slice-2-gate
  axis (ADR-0026; the paying gate reads the org). Mirrors
  Instance.SetOrganizationFromActor: the lookup propagates the action's
  actor/authorize? (a platform admin owns their personal org, so the
  authorized read passes policy); no actor → the `present(:organization_id)`
  validation answers with a field-scoped message, never a bare Forbidden.

  The paying gate is deliberately NOT here — slice 2 owns it
  (fluxvale/fluxvale#412): writes are admin-only this ticket.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, %{actor: actor} = context) when not is_nil(actor) do
    case FluxVale.Accounts.personal_org_for_user(
           actor.id,
           actor: actor,
           authorize?: Map.get(context, :authorize?, true)
         ) do
      {:ok, org} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:created_by_user_id, actor.id)
        |> Ash.Changeset.force_change_attribute(:organization_id, org.id)

      :none ->
        # Not producible through actions (signup JIT provisions the org
        # in the same transaction as the user — tests reach this via
        # Ash.seed!); a loud field-scoped message beats a bare
        # required-field error if an actor ever lacks an org.
        Ash.Changeset.add_error(changeset, field: :organization_id, message: "is required")

      # coveralls-ignore-start - defensive: DB read failure mid-create,
      # not simulatable under the sandbox
      {:error, _error} ->
        Ash.Changeset.add_error(changeset, field: :organization_id, message: "org lookup failed")

        # coveralls-ignore-stop
    end
  end

  def change(changeset, _opts, _context) do
    # No actor: the `present(:organization_id)` create validation reports
    # it with a field-scoped message instead of an actor-shaped crash here.
    changeset
  end

  @impl Ash.Resource.Change
  def atomic?, do: false
end
