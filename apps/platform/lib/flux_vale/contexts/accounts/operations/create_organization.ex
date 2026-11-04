defmodule FluxVale.Accounts.Operations.CreateOrganization do
  @moduledoc """
  Creates a team Organization for a signed-in user (#408): the actor
  becomes its single `:owner` member in the same transaction (the
  action's in-transaction manage_relationship — callers cannot name
  members). The org is a TEAM org by construction: `personal_owner_id`
  stays null, the marker is provisioning's to stamp and the action never
  accepts it from input.

  Owner ruling (Nov 4, #408): membership roles stay the single enum axis
  on the grant row — `:owner`/`:member` today, finer roles later as enum
  values on the SAME rows. No booleans, no second table.

  No wallet and no welcome credits: the $3 grant is the per-user signup
  entitlement (#122) — orgs are the abuse boundary. A team org gets its
  wallet lazily via `FluxVale.Billing.ensure_wallet/1` when a billing
  surface first touches it.
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Identity.User

  @spec call(User.t(), %{name: String.t(), slug: String.t()}) ::
          {:ok, Organization.t()} | {:error, term()}
  def call(%User{} = user, %{name: _name, slug: _slug} = params) do
    Organization
    |> Ash.Changeset.for_create(:create_with_owner, params)
    |> Ash.create(actor: user, authorize?: true)
  end
end
