defmodule FluxVale.Infrastructure.Instance.PerformSettle do
  @moduledoc """
  The `:settle_usage` trigger's change wrapper (#121, ADR-0005 Am. 1 /
  ADR-0028) — the settle arithmetic itself lives in
  `Instance.SettleUsage`, the core it shares with #493's resize (the
  resize settles the open interval at the in-force rate before
  flipping, so no hour straddles two prices).
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.Instance.SettleUsage

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      SettleUsage.settle_now(record)
    end)
  end
end
