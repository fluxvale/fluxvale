defmodule FluxVale.Checks.ActorIsOrganizationMember do
  @moduledoc """
  Policy check: the create's NAMED org — the `organization_id` the
  tenancy change (`SetOrganizationFromActor`) set on the changeset
  before policies run — counts the actor among its members. The
  membership fence for #408's context creates: naming an org you don't
  belong to is Forbidden, whatever that org's wallet looks like.

  Why not the filter-check cousin (`relates_to_actor_via`) on a create:
  the exists over the relationship path evaluates `:unknown` for a
  non-member (resolving the org runs the actor-authorized org read,
  which a non-member cannot pass), and that unknown falls into Ash's
  scenario-solving, which can allow the create. This check reads the
  grant row authorize-free — the `ActorOrgWalletFunded` posture: the
  check IS the authorization — and answers true/false, never unknown.

  Row-scoped policies (reads, updates, destroys) stay on
  `relates_to_actor_via`: with the row in the database the filter
  check is exact. This check is for creates, where the row is only a
  template.
  """

  use Ash.Policy.SimpleCheck

  alias FluxVale.Accounts.Membership

  require Ash.Query

  @impl Ash.Policy.Check
  def describe(_opts), do: "the actor is a member of the create's named org"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, context, _opts) when not is_nil(actor) do
    case named_org_id(context.subject) do
      nil -> false
      org_id -> member?(org_id, actor.id)
    end
  end

  # No actor: false — the create policies' own actor_present forbid
  # answers that shape with the same verdict.
  def match?(_actor, _context, _opts), do: false

  # The tenancy change sets organization_id from the create's argument
  # before policies run, so the attribute IS the org the row will
  # carry. No attribute (no tenancy change on the action, or the
  # orgless-actor shape its own validation answers): nothing to be a
  # member of, fail closed.
  defp named_org_id(%Ash.Changeset{} = changeset) do
    Ash.Changeset.get_attribute(changeset, :organization_id)
  end

  defp named_org_id(_subject), do: nil

  @doc """
  The predicate: does this org count this user among its members? A
  missing org has no members (false), the same as a missing grant.
  """
  @spec member?(Ash.UUID.t(), Ash.UUID.t()) :: boolean()
  def member?(org_id, user_id) do
    Membership
    |> Ash.Query.filter(organization_id == ^org_id and user_id == ^user_id)
    |> Ash.exists?(authorize?: false)
  end
end
