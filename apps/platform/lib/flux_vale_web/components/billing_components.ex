defmodule FluxValeWeb.BillingComponents do
  @moduledoc """
  Shared billing render pieces (#276): the wallet facts and the
  paginated ledger history. Extracted from `BillingLive.Index` when the
  org billing view (`/organizations/:slug/billing`) needed the same shape
  over a URL-resolved org. The top-up CTA and its notice stay
  page-owned — the wizard is personal-org-pinned — so only the genuinely
  identical markup lives here.
  """

  use FluxValeWeb, :html

  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Month
  alias FluxVale.Pricing

  @micro_per_cent 10_000

  @doc """
  The wallet facts as the grammar's in-band posture (S9, the S4/S6
  shape): Balance and Runway as eyebrow-labeled values. The projection
  is `Billing.compute_runway/1` — the same struct the dashboard's band
  shows, so the two surfaces can never disagree about the wallet.

  The pair stacks below 760px and sits end-anchored side-by-side above:
  the runway value's longest shape ("No active burn") is wider than the
  S6 pair's fixtures, so the S6 at-375 side-by-side fit doesn't hold
  here — the stack is the measured composition, not a wrap.
  """
  attr(:facts, :any,
    required: true,
    doc: "the Billing.compute_runway/1 projection: balance, runway, burn"
  )

  @spec wallet_facts(map()) :: Phoenix.LiveView.Rendered.t()
  def wallet_facts(assigns) do
    ~H"""
    <div class="flex flex-col gap-y-6 min-[760px]:flex-row min-[760px]:items-start min-[760px]:gap-x-14">
      <div data-testid="wallet-balance">
        <p class="eyebrow">Balance</p>
        <p class="mt-1.5 whitespace-nowrap text-3xl font-bold tracking-tight text-ink min-[760px]:text-4xl min-[900px]:text-5xl">
          {format_balance(@facts.balance_cents)}
        </p>
      </div>

      <div data-testid="wallet-runway">
        <p class="eyebrow">Runway</p>
        <p class="mt-1.5 whitespace-nowrap text-3xl font-bold tracking-tight text-ink min-[760px]:text-4xl min-[900px]:text-5xl">
          {format_runway(@facts)}
        </p>
        <p class="mt-1 text-xs text-ink-subtle">{burn_hint(@facts)}</p>
      </div>
    </div>
    """
  end

  @doc """
  The paginated ledger history rows: the empty state, the newest-first
  stream rows, and the "Load more" button — retired at exhaustion via
  `page.more?`. Appends ride the rendering LiveView's "load-more"
  handler; the component owns only the markup. The section heading is
  the pages' (S9: the S4/S6 section shape — heading outside the card).
  Timestamps and amounts ride the mono register — ledger rows are
  technical content (S8's confirm-step register).
  """
  attr(:entries, :list, required: true, doc: "the stream: {dom_id, entry} tuples")
  attr(:page, :any, required: true, doc: "the current Ash keyset page (more? gates the button)")

  attr(:history_empty?, :boolean, required: true, doc: "no rows at all — the empty state")

  @spec ledger_history(map()) :: Phoenix.LiveView.Rendered.t()
  def ledger_history(assigns) do
    ~H"""
    <.card>
      <%!-- Empty state lives OUTSIDE the stream container: streams
          can't count, and an in-stream hidden placeholder makes
          divide/border selectors render a phantom row divider
          (vision QA round 2). --%>
      <p :if={@history_empty?} class="text-sm text-ink-subtle" data-testid="ledger-empty">
        No activity yet.
      </p>
      <div id="entries" phx-update="stream">
        <div
          :for={{dom_id, entry} <- @entries}
          id={dom_id}
          data-testid="ledger-row"
          class="flex items-center justify-between gap-4 border-t border-line py-3 first:border-t-0"
        >
          <%!-- The mono register steps down below 480px: the fixed-format
              timestamp (22 mono chars) plus the widest fixture amount
              overshoots the 320 viewport by ~1px at text-sm — measured,
              the S6 lesson (the guard is the row's own arithmetic, not
              a wrap). --%>
          <span class="font-mono text-xs whitespace-nowrap text-ink-muted min-[480px]:text-sm">
            {Calendar.strftime(entry.created_at, "%b %d, %Y %H:%M UTC")}
          </span>
          <span class="min-w-0 flex-1 truncate text-sm text-ink capitalize">
            {reason_label(entry.reason)}
          </span>
          <span class={[
            "font-mono text-xs whitespace-nowrap min-[480px]:text-sm",
            amount_color(entry)
          ]}>
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

  # The runway copy is the dashboard's formatter shape (S4), owned at
  # the billing display seam: a spent wallet is out of runway — "under
  # an hour" would read as nearly-there — and :infinity (no burn) reads
  # as itself. The divisor is the average Gregorian month (Billing.Month),
  # the same constant the projection and the settles use.
  defp format_runway(%{balance_cents: cents}) when cents < 0, do: "Depleted"
  defp format_runway(%{runway_hours: :infinity}), do: "No active burn"

  defp format_runway(%{runway_hours: hours}) when hours < 1, do: "under an hour"

  defp format_runway(%{runway_hours: hours}) when hours < 48,
    do: "≈ #{round(hours)} #{plural(round(hours), "hour")}"

  defp format_runway(%{runway_hours: hours}) do
    days = hours / 24

    if days < 60 do
      "≈ #{round(days)} #{plural(round(days), "day")}"
    else
      months = days * 24 * 3600 / Month.seconds()
      "≈ #{round(months)} #{plural(round(months), "month")}"
    end
  end

  defp burn_hint(%{burn_micro_cents_per_hour: 0}), do: "Nothing burning right now."

  defp burn_hint(%{burn_micro_cents_per_hour: burn_micro}) do
    # ComputeRunway truncates the rate into µ¢/h (hourly_micro's div);
    # reconstructing with div would truncate again — every rate then
    # displays a cent low ($1.00/mo read "$0.99/mo", $10.00/mo
    # "$9.99/mo"). Half-up rounding recovers the nearest cent of the
    # already-truncated rate (CodeRabbit #351).
    half_divisor = div(@micro_per_cent * 3600, 2)

    monthly_cents =
      div(burn_micro * Month.seconds() + half_divisor, @micro_per_cent * 3600)

    "at #{Pricing.format_usd(monthly_cents)}/mo current burn"
  end

  defp plural(1, unit), do: unit
  defp plural(_n, unit), do: "#{unit}s"

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
