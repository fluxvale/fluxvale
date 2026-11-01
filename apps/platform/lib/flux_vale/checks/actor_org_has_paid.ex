defmodule FluxVale.Checks.ActorOrgHasPaid do
  @moduledoc """
  Policy check: the org in play has PAID REAL MONEY at least once — one
  completed $1+ top-up, ever. Private-access enablement is a paid
  add-on's surface: the $3 welcome credit every org gets at signup must
  not unlock it (a bot gets welcome credits, never a card). The test is
  the ledger's shape, not the balance: reason `:purchase` is the
  payment-webhook's reason (`CreditWallet`), so goodwill/adjustment
  grants never qualify. Refunds post compensating debits (`ReverseEntry`)
  that this check ignores — a paid org stays paid. Wired to AccessGateway
  `create` and `resume` beside the funded check.

  The org in play resolves by action shape: creates resolve the actor's
  personal org — the same lookup `SetOrganizationFromActor` pins the row
  with moments later. Updates re-read the ROW from the database: an
  in-process caller controls the changeset's in-memory struct, and the
  gate must not be caller-controlled. An actor with no org passes the
  check so the create's own `organization_id is required` validation
  answers instead of a bare Forbidden (the ActorOrgWalletFunded stance).
  """

  use Ash.Policy.SimpleCheck

  alias FluxVale.Accounts
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Wallet

  require Ash.Query

  # The $1 floor in whole cents. Product decision: ONE real payment
  # event of at least $1 ever unlocks — welcome/goodwill credits do not
  # (the reason dimension is what separates a card from a bot).
  @min_purchase_cents 100

  @impl Ash.Policy.Check
  def describe(_opts), do: "the org has paid at least once (a $1+ top-up)"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, context, _opts) do
    case row_org_id(context.subject) do
      :create -> paid_via_actor?(actor)
      {:ok, org_id} -> org_paid?(org_id)
      # Reload failure (row gone, DB down): fail closed.
      :error -> false
    end
  end

  @doc """
  The predicate: has this org ever posted a qualifying purchase credit?
  A wallet-less org has never paid (there is no ledger to hold one).
  """
  @spec org_paid?(Ash.UUID.t()) :: boolean()
  def org_paid?(org_id) do
    case Wallet.get_by_organization(org_id, authorize?: false) do
      {:ok, wallet} -> purchase_credited?(wallet)
      {:error, _no_wallet} -> false
    end
  end

  # authorize?: false — the check IS the authorization (the
  # ActorOrgWalletFunded posture).
  defp purchase_credited?(wallet) do
    floor = @min_purchase_cents

    LedgerEntry
    |> Ash.Query.filter(
      wallet_id == ^wallet.id and type == :credit and reason == :purchase and amount >= ^floor
    )
    |> Ash.exists?(authorize?: false)
  end

  # Updates carry the loaded record — but an in-process caller controls
  # that struct, so the org comes off a FRESH DB read of the row, never
  # the in-memory attribute. Creates carry no row yet → the actor path.
  defp row_org_id(%Ash.Changeset{data: %_record{organization_id: nil}}), do: :create

  defp row_org_id(%Ash.Changeset{data: data}) do
    case Ash.reload(data, authorize?: false) do
      {:ok, fresh_row} -> {:ok, fresh_row.organization_id}
      {:error, _reload_failure} -> :error
    end
  end

  defp row_org_id(_subject), do: :create

  # The actor's org is what SetOrganizationFromActor will pin the row
  # with — the same wallet the created gateway bills. No org at all
  # passes (see the moduledoc).
  defp paid_via_actor?(actor) do
    case Accounts.personal_org_for_user(actor.id, authorize?: false) do
      {:ok, org} -> org_paid?(org.id)
      :none -> true
    end
  end
end
