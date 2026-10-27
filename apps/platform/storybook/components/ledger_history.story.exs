defmodule FluxValeWeb.Storybook.Components.LedgerHistory do
  @moduledoc """
  Ledger-history stories — the paginated billing history (#276). Rows
  are hand-built `LedgerEntry` structs (the component renders fields, no
  reads, the backup_run_row posture); `page` stands in for the Ash page
  whose `more?` gates the Load more button.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.BillingComponents.ledger_history/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :more_pages,
        description: "Credits and debits, newest first — another page waits",
        attributes: %{entries: entries(), page: %{more?: true}, history_empty?: false}
      },
      %Variation{
        id: :final_page,
        description: "The last page — the Load more button is retired",
        attributes: %{entries: entries(), page: %{more?: false}, history_empty?: false}
      },
      %Variation{
        id: :empty,
        description: "A wallet with no rows — the empty state lives outside the stream",
        attributes: %{entries: [], page: %{more?: false}, history_empty?: true}
      }
    ]
  end

  # Newest first, the order the page's keyset read produces.
  defp entries do
    [
      {"entries-01", entry(~U[2026-10-27 04:00:00Z], :purchase, :credit, 25_000)},
      {"entries-02", entry(~U[2026-10-27 03:30:00Z], :welcome, :credit, 300)},
      {"entries-03", entry(~U[2026-10-27 03:00:00Z], :usage, :debit, 1_250)}
    ]
  end

  defp entry(created_at, reason, type, amount) do
    %FluxVale.Billing.LedgerEntry{
      id: Ash.UUID.generate(),
      created_at: created_at,
      reason: reason,
      type: type,
      amount: amount
    }
  end
end
