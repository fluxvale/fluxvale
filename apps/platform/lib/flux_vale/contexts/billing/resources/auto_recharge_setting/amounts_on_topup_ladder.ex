defmodule FluxVale.Billing.AutoRechargeSetting.AmountsOnTopupLadder do
  @moduledoc """
  `threshold_cents` and `amount_cents` follow the top-up ladder (#888,
  `FluxVale.Billing.topup_amount_valid?/1`) — the same rule the wizard
  and StartTopup enforce, so a saved write can never store an amount a
  top-up would refuse. A row that predates the ladder keeps its stored
  values (see below).

  The check is scoped to what the write CARRIES: a field is judged only
  when the action's params include it (string or atom key). A mode-only
  save — turning reminders off — must keep working on any row, and a
  future ladder edit must not need a data migration. A write that does
  carry the field is judged on its value even when that equals the
  stored one, so an older off-ladder value cannot be re-confirmed. A
  row that still HOLDS a pre-ladder value is never armed to charge it:
  `AutoArmGate` refuses that separately.

  An attribute `constraints(min:)` cannot carry this: the rungs come
  from config at run time, not a compile-time literal.
  """

  use Ash.Resource.Validation

  @fields [:amount_cents, :threshold_cents]

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, _context) do
    case Enum.flat_map(@fields, &field_errors(changeset, &1)) do
      [] -> :ok
      [error | _rest] -> error
    end
  end

  # The ladder error for a written field, or [] when the write does
  # not carry it (the write-scoped rule — see the moduledoc).
  defp field_errors(changeset, field) do
    if written?(changeset, field) do
      case check(changeset, field) do
        :ok -> []
        {:error, _reason} = error -> [error]
      end
    else
      []
    end
  end

  # A carried param counts as written even when Ash drops it as an
  # equal-to-data change: the submitted value is what the owner asked
  # for (the :set action's own `mode` change reads params this way).
  defp written?(changeset, field) do
    Map.has_key?(changeset.params, field) or
      Map.has_key?(changeset.params, Atom.to_string(field))
  end

  defp check(changeset, field) do
    amount = Ash.Changeset.get_attribute(changeset, field)

    if FluxVale.Billing.topup_amount_valid?(amount) do
      :ok
    else
      {:error, field: field, message: "must be a top-up ladder rung or above its top rung"}
    end
  end
end
