defmodule FluxVale.Billing.Operations.SyncPaymentMethod do
  @moduledoc """
  The billing card's mount-time method sync (#829 S5): one cheap
  provider GET per mount answers whether a saved method exists.

  **This poll IS the sync** — Polar has no method-attached webhook, so
  nothing else flips `payment_method_status` after the buyer saves (or
  removes) a method in the portal. Every mount of the card on a row
  with a stored provider customer re-reads the truth; the default
  method reference the provider returns is informational (the setting
  carries no field for it — the ref is dropped, never logged).

  `count > 0` → `:attached`, `0` → `:none` (a method removed in the
  portal un-attaches on the next mount). A provider error leaves the
  stored state UNCHANGED — the next mount retries; the sweep's own
  pre-charge lookup (S4) is the authoritative check either way.

  Gate-on only (the card calls it only gate-on, and the seam re-checks
  — a call with the gate off is a bug that must answer, not charge).
  The write rides `:set_method_status`, the system action
  (authorize?: false — actor-forbidden by policy).
  """

  alias FluxVale.Billing
  alias FluxVale.Billing.AutoRechargeSetting

  @spec call(AutoRechargeSetting.t()) ::
          {:ok, :attached | :none | :no_customer, AutoRechargeSetting.t()} | {:error, term()}
  def call(setting) do
    if Billing.auto_recharge_charge_mode?() do
      sync(setting)
    else
      {:error, :charge_mode_off}
    end
  end

  # No stored customer yet — nothing to ask the provider; the row's
  # :none stands (the "Add payment method" click creates the customer).
  defp sync(%AutoRechargeSetting{provider_customer_id: nil} = setting),
    do: {:ok, :no_customer, setting}

  defp sync(setting) do
    provider = Application.fetch_env!(:flux_vale, :payments_provider)

    case provider.list_payment_methods(setting.provider_customer_id) do
      {:ok, count, _informational_ref} ->
        status = if count > 0, do: :attached, else: :none

        # The no-op short-circuit: the provider AGREES with the stored
        # status — skip the write entirely. Without it, every mount of
        # every card mints a paper-trail version row for a write that
        # changes nothing (three linked Ash/ash_paper_trail internals
        # would have to silently no-op the identical write — never
        # assume that chain, short-circuit here).
        if status == setting.payment_method_status do
          {:ok, status, setting}
        else
          write(setting, status)
        end

      # Unknown answer — the stored state stands untouched and the next
      # mount retries (never flip a status on a fault).
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write(setting, status) do
    result =
      setting
      |> Ash.Changeset.for_update(:set_method_status, %{
        payment_method_status: status,
        provider_customer_id: setting.provider_customer_id
      })
      |> Ash.update(authorize?: false)

    case result do
      {:ok, updated} -> {:ok, status, updated}
      {:error, reason} -> {:error, reason}
    end
  end
end
