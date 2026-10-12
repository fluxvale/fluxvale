defmodule FluxVale.Billing.LedgerEntry.SignMatchesType do
  @moduledoc """
  The ledger's core invariant at the Ash layer: a `:credit` entry must
  carry a positive `amount`, a `:debit` a negative one. The database
  check constraint mirrors this for rows written outside Ash — the
  defense-in-depth port from v1.
  """

  use Ash.Resource.Validation

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, _context) do
    type = Ash.Changeset.get_attribute(changeset, :type)
    amount = Ash.Changeset.get_attribute(changeset, :amount)

    sign_ok? =
      case {type, amount} do
        {:credit, amount} when is_integer(amount) -> amount > 0
        {:debit, amount} when is_integer(amount) -> amount < 0
        _other -> false
      end

    if sign_ok? do
      :ok
    else
      {:error, field: :amount, message: "sign must match type"}
    end
  end
end
