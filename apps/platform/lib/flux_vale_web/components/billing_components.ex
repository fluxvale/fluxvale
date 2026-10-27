defmodule FluxValeWeb.BillingComponents do
  @moduledoc """
  Shared billing render pieces (#276): the balance header and the
  paginated ledger history. Extracted from `BillingLive.Index` when the
  org billing view (`/organizations/:slug/billing`) needed the same shape
  over a URL-resolved org. The top-up CTA and its notice stay
  page-owned — the wizard is personal-org-pinned — so only the genuinely
  identical markup lives here.
  """

  use FluxValeWeb, :html

  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Pricing

  @doc """
  The balance header: the label and the live ledger sum, signed USD —
  the ledger carries signed cents, so a negative balance renders a minus.
  """
  attr(:balance, :integer, required: true, doc: "the wallet balance in integer cents")

  @spec balance_header(map()) :: Phoenix.LiveView.Rendered.t()
  def balance_header(assigns) do
    ~H"""
    <div>
      <h2 class="text-sm font-medium text-ink-muted">Balance</h2>
      <p class="mt-1 text-4xl font-bold tracking-tight text-ink" data-testid="wallet-balance">
        {format_balance(@balance)}
      </p>
    </div>
    """
  end

  @doc """
  The paginated ledger history: the empty state, the newest-first stream
  rows, and the "Load more" button — retired at exhaustion via
  `page.more?`. Appends ride the rendering LiveView's "load-more"
  handler; the component owns only the markup.
  """
  attr(:entries, :list, required: true, doc: "the stream: {dom_id, entry} tuples")
  attr(:page, :any, required: true, doc: "the current Ash keyset page (more? gates the button)")

  attr(:history_empty?, :boolean, required: true, doc: "no rows at all — the empty state")

  @spec ledger_history(map()) :: Phoenix.LiveView.Rendered.t()
  def ledger_history(assigns) do
    ~H"""
    <.card>
      <h2 class="text-sm font-medium text-ink-muted">History</h2>
      <%!-- Empty state lives OUTSIDE the stream container: streams
          can't count, and an in-stream hidden placeholder makes
          divide/border selectors render a phantom row divider
          (vision QA round 2). --%>
      <p :if={@history_empty?} class="mt-3 text-sm text-ink-subtle" data-testid="ledger-empty">
        No activity yet.
      </p>
      <div id="entries" phx-update="stream" class="mt-2">
        <div
          :for={{dom_id, entry} <- @entries}
          id={dom_id}
          data-testid="ledger-row"
          class="flex items-center justify-between gap-4 border-t border-line py-3 first:border-t-0"
        >
          <span class="text-sm whitespace-nowrap text-ink-muted">
            {Calendar.strftime(entry.created_at, "%b %d, %Y %H:%M UTC")}
          </span>
          <span class="min-w-0 flex-1 truncate text-sm text-ink capitalize">
            {reason_label(entry.reason)}
          </span>
          <span class={["font-mono text-sm whitespace-nowrap", amount_color(entry)]}>
            {format_amount(entry.amount)}
          </span>
        </div>
      </div>
      <div class="mt-4">
        <.button :if={@page.more?} id="load-more" variant="ghost" size="sm" phx-click="load-more">
          Load more
        </.button>
      </div>
    </.card>
    """
  end

  # Prices (Pricing.format_usd/1) are non-negative by constraint; the
  # ledger carries signed cents — negative balances and debit rows get
  # their own sign handling here, at the billing display seam.
  defp format_balance(cents) when cents < 0 do
    "-" <> Pricing.format_usd(-cents)
  end

  defp format_balance(cents) do
    Pricing.format_usd(cents)
  end

  defp format_amount(cents) when cents < 0 do
    "-" <> Pricing.format_usd(-cents)
  end

  defp format_amount(cents) do
    "+" <> Pricing.format_usd(cents)
  end

  defp amount_color(%LedgerEntry{type: :credit}) do
    "text-success"
  end

  defp amount_color(%LedgerEntry{type: :debit}) do
    "text-danger"
  end

  # Display copy at the billing seam: raw reason atoms read as bare
  # words — "welcome" deserves its product name (vision QA round 2).
  defp reason_label(:welcome), do: "Welcome credit"

  defp reason_label(reason) when is_atom(reason) do
    word = to_string(reason)
    String.capitalize(word)
  end
end
