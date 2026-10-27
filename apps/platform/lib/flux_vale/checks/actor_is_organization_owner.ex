defmodule FluxVale.Checks.ActorIsOrganizationOwner do
  @moduledoc """
  Policy check: the actor holds an `:owner` membership of the subject
  Organization — the gate behind the org rename flow (#276). Policy-land
  and LiveView-land both answer "is this actor this org's owner" through
  this module, so the notion cannot fork (the ActorIsPlatformAdmin
  stance).

  Mere membership is not enough: the `:member` role can read the org,
  settings included — renaming is the owner's call.
  """

  use Ash.Policy.SimpleCheck

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization

  require Ash.Query

  @impl Ash.Policy.Check
  def describe(_opts), do: "actor is an owner of the organization"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, context, _opts), do: owner?(actor, context.subject)

  @doc """
  The plug/LiveView-facing predicate — same answer as the policy check.
  The subject is the record in UI land, the update changeset in policy
  land; both carry the org id the membership resolves against.
  """
  @spec owner?(map() | nil, Organization.t() | Ash.Changeset.t()) :: boolean()
  def owner?(%{id: user_id}, %Organization{id: org_id}) do
    owner_membership?(user_id, org_id)
  end

  def owner?(%{id: user_id}, %Ash.Changeset{data: %Organization{id: org_id}}) do
    owner_membership?(user_id, org_id)
  end

  def owner?(_actor, _subject), do: false

  # authorize?: false — the check IS the authorization; the membership
  # read policy can't gate its own gate (the ActorOrgWalletFunded posture).
  defp owner_membership?(user_id, org_id) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(user_id == ^user_id and organization_id == ^org_id and role == :owner)
    |> Ash.exists?(authorize?: false)
  end
end
