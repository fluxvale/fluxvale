defmodule FluxVale.Checks.ActorOrgWalletFunded do
  @moduledoc """
  Policy check: the org in play has a wallet balance > 0 — #124's
  deploy gate. Policy-land, not UI-land, so the API can't walk around
  it; wired to Instance `create` (new deploys) and `start` (resuming
  spends too — create-while-positive, stop, start-at-zero would
  otherwise route around the gate).

  The org in play resolves by action shape: updates read it off the
  loaded record (`changeset.data.organization_id`); creates resolve the
  actor's personal org — the same lookup `SetOrganizationFromActor`
  pins the row with moments later. An actor with no org passes the
  check so the create's own `organization_id is required` validation
  answers instead of a bare Forbidden.
  """

  use Ash.Policy.SimpleCheck

  alias FluxVale.Accounts
  alias FluxVale.Billing.Wallet

  @impl Ash.Policy.Check
  def describe(_opts), do: "the org's wallet balance is positive"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, context, _opts) do
    case org_id(context.subject) do
      nil -> funded_via_actor?(actor)
      org_id -> org_funded?(org_id)
    end
  end

  @doc """
  The predicate: does this org's wallet hold a positive balance? A
  wallet-less org is unfunded (balance 0 by definition — the ledger is
  the balance).
  """
  @spec org_funded?(Ash.UUID.t()) :: boolean()
  def org_funded?(org_id) do
    case Wallet.get_by_organization(org_id, authorize?: false) do
      {:ok, wallet} ->
        {:ok, loaded} = Ash.load(wallet, :balance, authorize?: false)
        (loaded.balance || 0) > 0

      {:error, _no_wallet} ->
        false
    end
  end

  # Updates carry the loaded record; creates don't (nil → actor path).
  defp org_id(%Ash.Changeset{data: %_record{organization_id: org_id}}) when not is_nil(org_id),
    do: org_id

  defp org_id(_subject), do: nil

  # The actor's org is what SetOrganizationFromActor will pin the row
  # with — the same wallet the created instance will accrue against.
  # No org at all passes (see the moduledoc).
  defp funded_via_actor?(actor) do
    case Accounts.personal_org_for_user(actor.id, authorize?: false) do
      {:ok, org} -> org_funded?(org.id)
      :none -> true
    end
  end
end
