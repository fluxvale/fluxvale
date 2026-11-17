defmodule FluxVale.Billing.AutoRechargeSetting.AutoArmGate do
  @moduledoc """
  Arming `mode: :auto` passes two checks, in order (#829, decision C):

  1. the platform gate — `FluxVale.Billing.auto_recharge_charge_mode?/0`
     stays false until the Polar Pro upgrade (activation slice S6);
  2. a saved method — `payment_method_status == :attached`; recurring
     charges without a method on file are not consentable.

  This is a VALIDATION, not a policy: a policy answers actor questions,
  and the gate is platform state — the same :auto write is legal or not
  for every actor alike. The gate fires only when the write SETS the
  mode (an unchanged :auto row is not re-consented here; the sweep's
  charge arm is gated separately in S4).
  """

  use Ash.Resource.Validation

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

      true ->
        :ok
    end
  end
end
