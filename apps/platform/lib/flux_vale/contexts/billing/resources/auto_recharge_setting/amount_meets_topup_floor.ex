defmodule FluxVale.Billing.AutoRechargeSetting.AmountMeetsTopupFloor do
  @moduledoc """
  `amount_cents` clears the wallet top-up floor at RUNTIME
  (`FluxVale.Billing.min_topup_cents/0`) — the same gate StartTopup
  enforces on a manual top-up, so a saved amount that could never
  charge is refused at write time. An attribute `constraints(min:)`
  cannot carry this: the floor is config, not a compile-time int.
  """

  use Ash.Resource.Validation

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, _context) do
    amount = Ash.Changeset.get_attribute(changeset, :amount_cents)
    minimum = FluxVale.Billing.min_topup_cents()

    if is_integer(amount) and amount >= minimum do
      :ok
    else
      {:error, field: :amount_cents, message: "must be at least the #{minimum}-cent top-up floor"}
    end
  end
end
