defmodule FluxValeWeb.FeedbackLive.OrgChoice do
  @moduledoc """
  The feedback islands' org-picker state (fluxvale/fluxvale#412, T5):
  the orgs a signed-in actor OWNS, the picker's default (the personal
  org), and the top-up path a gate-refused org links to. The vote island
  and the composer share this module so their pickers cannot disagree
  about what "own" or "default" means.

  The ownership notion is the write gate's own (`ActorIsOrganizationOwner`
  behind `ActorOwnsPaidOrg`) — this module only ASKS it, never answers
  it. The UI is affordance only: a tampered client picking an org it
  does not own still hits the actions' policies.
  """

  use FluxValeWeb, :verified_routes

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Organization
  alias FluxVale.Identity.User

  @doc """
  The orgs the actor owns — the picker's rows, oldest (the personal org,
  provisioned in the signup transaction) first. An org-less actor (the
  seeded straggler shape) owns nothing.
  """
  @spec choices(User.t()) :: [Organization.t()]
  def choices(user) do
    {:ok, orgs} = Accounts.owned_orgs_for_user(user.id, actor: user)

    orgs
  end

  @doc """
  The picker's default: the actor's personal org when they own it (the
  marker read, #408), else their first owned org. `nil` for an actor
  with no owned org — the vote would fail closed at the gate anyway.
  """
  @spec default(User.t(), [Organization.t()]) :: Organization.t() | nil
  def default(_user, []), do: nil

  def default(user, orgs) do
    case Accounts.personal_org_for_user(user.id, actor: user) do
      {:ok, personal} ->
        Enum.find(orgs, &(&1.id == personal.id)) || hd(orgs)

      :none ->
        hd(orgs)
    end
  end

  @doc """
  The top-up flow for the gate-refused copy's link: the org's own wizard
  for a team org, the account's for the personal org (its slug-keyed URL
  would redirect anyway) and for an org-less actor.
  """
  @spec topup_path(Organization.t() | nil) :: String.t()
  def topup_path(nil), do: ~p"/billing/topup"
  def topup_path(%Organization{personal_owner_id: id}) when not is_nil(id), do: ~p"/billing/topup"
  def topup_path(%Organization{} = org), do: ~p"/organizations/#{org.slug}/billing/topup"
end
