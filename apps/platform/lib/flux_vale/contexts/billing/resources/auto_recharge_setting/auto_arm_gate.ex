defmodule FluxVale.Billing.AutoRechargeSetting.AutoArmGate do
  @moduledoc """
  Arming `mode: :auto` passes two checks, in order (#829, decision C):

  1. the platform gate — `FluxVale.Billing.auto_recharge_charge_mode?/0`
     stays false until the Polar Pro upgrade (activation slice S6);
  2. a saved method — `payment_method_status == :attached`; recurring
     charges without a method on file are not consentable;
  3. the ladder (#888) — the STORED threshold and amount must be on the
     top-up ladder; a row that predates it is never armed to charge a
     value a top-up would refuse (the write-scoped
     AmountsOnTopupLadder leaves stored values alone).

  This is a VALIDATION, not a policy: a policy answers actor questions,
  and the gate is platform state — the same :auto write is legal or not
  for every actor alike. The gate fires only when the write SETS the
  mode (an unchanged :auto row is not re-consented here; the sweep's
  charge arm is gated separately in S4).
  """

  use Ash.Resource.Validation

  alias FluxVale.Billing

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :mode) do
      {:ok, :auto} -> arm_checks(changeset)
      _not_being_set_to_auto -> :ok
    end
  end

  defp arm_checks(changeset) do
    cond do
      not FluxVale.Billing.auto_recharge_charge_mode?() ->
        {:error,
         field: :mode, message: "the auto-recharge charge lane is not enabled on this platform"}

      Ash.Changeset.get_attribute(changeset, :payment_method_status) != :attached ->
        {:error, field: :mode, message: "arming :auto requires a saved payment method"}

      not ladder_valid?(changeset) ->
        {:error,
         field: :mode,
         message: "arming :auto requires a threshold and amount on the top-up ladder"}

      true ->
        :ok
    end
  end

  defp ladder_valid?(changeset) do
    amount = Ash.Changeset.get_attribute(changeset, :amount_cents)
    threshold = Ash.Changeset.get_attribute(changeset, :threshold_cents)
    Billing.topup_amount_valid?(amount) and Billing.topup_amount_valid?(threshold)
  end
end
