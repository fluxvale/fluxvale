defmodule FluxValeWeb.AdminLive.WalletDetail do
  @moduledoc """
  One wallet's oversight view (#501): the org's facts (balance and the
  runway projection via the domain's `compute_runway/1`), the paywall
  waiver with its contract in plain copy, and the ledger — keyset
  paginated, newest first, the #123 history shape. The writes are the
  two the surface owns:

  - the paywall waiver flip (`Wallet :set_waiver`, the one
    actor-facing wallet update): confirmed inline where the toggle
    lives, with the contract in the confirm copy — the waiver satisfies
    only the has-paid gate (private access, backups), moves no money,
    posts no ledger row, waives nothing spendable;
  - the goodwill credit (`LedgerEntry :grant_goodwill`, #140): posts
    immediately as an `:adjustment` credit through the same GrantCredits
    seam as every other posting. The action is KEYLESS by deliberation
    (the domain comment owns the reasoning), so the surface fences the
    wire (`phx-disable-with`) and the posted row renders at the top of
    the ledger with a reversal affordance — the operator review of the
    posted row is the guard the domain names.

  Reversal rides the system seam (`Billing.reverse_entry/2`, the
  compensating unwind). No actor-facing reversal action exists (the
  flagged gap, reported on the lane), so the handler enforces the gate
  itself: the platform-admin predicate (covering the demotion window
  the AdminGate mount check cannot) plus a fresh actor-authorized read
  of the entry, then the seam.

  Every read rides the billing domain with the platform-admin actor and
  authorization on. No `authorize?: false` anywhere on this surface.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Wallet
  alias FluxVale.Checks.ActorIsPlatformAdmin
  alias FluxValeWeb.AdminComponents
  alias FluxValeWeb.BillingComponents

  # Mirrors the org billing page's ledger window — the same read, the
  # same sort, one page size for every ledger surface.
  @page_size 25

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    admin = socket.assigns.current_user

    with {:ok, wallet} <- Ash.get(Wallet, id, actor: admin),
         {:ok, [org]} <- org_lookup(admin, [wallet.organization_id]) do
      case Billing.compute_runway(wallet) do
        {:ok, runway} ->
          page = ledger_page(wallet.id, admin)

          {:ok,
           socket
           |> assign(
             wallet: wallet,
             org: org,
             runway: runway,
             page: page,
             ledger_empty?: page.results == [],
             reversed_ids: reversed_ids(page.results),
             confirm: nil,
             goodwill_form: to_form(%{"amount_cents" => ""}, as: :goodwill)
           )
           |> stream(:entries, page.results)}

        # defensive: the projection fails only on a DB read failure —
        # not simulatable under the sandbox
        # coveralls-ignore-start
        {:error, _reason} ->
          {:ok,
           socket
           |> put_flash(:error, gettext("The wallet's numbers did not load. Try again."))
           |> push_navigate(to: ~p"/admin/billing")}

          # coveralls-ignore-stop
      end
    else
      # Unknown id (and the org-lookup empty arm, unreachable while the
      # org FK stands): one arm, one answer.
      _missing_or_denied ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That wallet does not exist."))
         |> push_navigate(to: ~p"/admin/billing")}
    end
  end

  # -- events ---------------------------------------------------------------

  # The waiver lever's click. The reveal rides a fresh domain read, so
  # the direction the confirm states is the wallet's CURRENT state, not
  # the mounted snapshot's (a flip raced between mount and click reads
  # the truth).
  @impl Phoenix.LiveView
  # coveralls-ignore-start - OTP 28 cover never attributes a count to
  # this clause head; the clause demonstrably runs (the waiver tests
  # drive it and the body's own lines all carry counts)
  def handle_event("open-waiver", _params, socket) do
    admin = socket.assigns.current_user
    # coveralls-ignore-stop

    case Ash.get(Wallet, socket.assigns.wallet.id, actor: admin) do
      {:ok, fresh} ->
        {:noreply, assign(socket, confirm: {:waiver, not fresh.paywall_waived}, wallet: fresh)}

      # Wallet rows are never deleted, so this arm is the DB-down
      # class — not simulatable under the sandbox.
      # coveralls-ignore-start
      {:error, _vanished} ->
        refused =
          put_flash(
            socket,
            :error,
            gettext("The wallet's state did not load. Try again.")
          )

        {:noreply, refused}
        # coveralls-ignore-stop
    end
  end

  # The waiver write: the one actor-facing wallet update, absolute
  # value, so the confirmed direction lands even if another admin
  # flipped in between (last confirmed intent wins — the flash states
  # the resulting state either way).
  def handle_event("confirm-waiver", _params, socket) do
    admin = socket.assigns.current_user
    {:waiver, target} = socket.assigns.confirm

    case Wallet.set_waiver(socket.assigns.wallet, %{paywall_waived: target}, actor: admin) do
      {:ok, waived} ->
        {:noreply,
         socket
         |> put_flash(:info, waiver_flash(target))
         |> assign(wallet: waived, confirm: nil)}

      # The policy admits this actor (the mount gate), so the residual
      # error class is DB-down — not simulatable under the sandbox.
      # coveralls-ignore-start
      {:error, _refused} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The waiver was refused. Try again."))
         |> assign(confirm: nil)}

        # coveralls-ignore-stop
    end
  end

  @impl Phoenix.LiveView
  def handle_event("cancel-confirm", _params, socket) do
    case socket.assigns.confirm do
      {:reverse, entry} ->
        # The panel lives inside the stream row, so the row re-renders.
        {:noreply,
         socket
         |> assign(confirm: nil)
         |> stream_insert(:entries, entry)}

      _waiver_or_nil ->
        {:noreply, assign(socket, confirm: nil)}
    end
  end

  # The goodwill credit (#140): keyless by deliberation, so the button
  # fences the wire (phx-disable-with) and each submit posts. The copy
  # says so before the click and the posted row lands at the top of
  # the ledger for the operator's review.
  @impl Phoenix.LiveView
  # coveralls-ignore-start - the same clause-head cover artifact; the
  # goodwill tests drive it and the body's lines carry counts
  def handle_event("grant-goodwill", %{"goodwill" => %{"amount_cents" => raw}}, socket) do
    admin = socket.assigns.current_user
    # coveralls-ignore-stop

    # The surface refuses politely before the domain ever sees it: a
    # whole number of cents, at least 1. The action's own constraint
    # stays the arbiter.
    case parse_cents(raw) do
      {:ok, cents} ->
        case LedgerEntry.grant_goodwill(socket.assigns.wallet.id, cents, actor: admin) do
          {:ok, entry} ->
            {:noreply,
             socket
             |> put_flash(:info, goodwill_posted_copy(cents))
             |> assign(goodwill_form: to_form(%{"amount_cents" => ""}, as: :goodwill))
             |> assign(ledger_empty?: false)
             |> refresh_facts()
             |> stream_insert(:entries, entry, at: 0)}

          # The policy admits this actor (the mount gate) and the
          # amount passed the guard above, so the residual error class
          # is DB-down — not simulatable under the sandbox.
          # coveralls-ignore-start
          {:error, _refused} ->
            refused =
              put_flash(
                socket,
                :error,
                gettext("The credit was refused. Nothing was posted. Try again.")
              )

            {:noreply, refused}
            # coveralls-ignore-stop
        end

      :error ->
        {:noreply,
         socket
         |> put_flash(:error, amount_invalid_copy())
         |> assign(goodwill_form: to_form(%{"amount_cents" => raw}, as: :goodwill))}
    end
  end

  # The reversal lever's click. The reveal rides a fresh actor-
  # authorized domain read (server-side state check), and the row's own
  # facts gate the rest: only a credit that is not itself a reversal
  # opens the confirm — anything else is the row-moved class, answered
  # with an honest refresh.
  def handle_event("open-reverse", %{"id" => id}, socket) do
    admin = socket.assigns.current_user

    with {:ok, entry} <- Ash.get(LedgerEntry, id, actor: admin),
         :credit <- entry.type,
         nil <- entry.reverses_id do
      {:noreply,
       socket
       |> assign(confirm: {:reverse, entry})
       |> stream_insert(:entries, entry)}
    else
      _changed ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That entry changed. The ledger is refreshed."))
         |> refresh_ledger()}
    end
  end

  # The compensating unwind. The seam is system-level (no actor-facing
  # reversal action exists — the flagged gap), so the admin gate is
  # enforced here: the platform-admin predicate first (the demotion
  # window), then the fresh actor-authorized read, then the seam. The
  # domain's own guard refuses a double reversal.
  def handle_event("confirm-reverse", _params, socket) do
    admin = socket.assigns.current_user
    {:reverse, entry} = socket.assigns.confirm

    if ActorIsPlatformAdmin.platform_admin?(admin) do
      attempt_reverse(socket, admin, entry)
    else
      # The mount gate checked at mount; a socket outlives a demotion.
      # Not simulatable past the mount (a demoted session cannot
      # mount) — the mount gate's own suite covers that path.
      # coveralls-ignore-start
      {:noreply, reverse_refused(socket)}
      # coveralls-ignore-stop
    end
  end

  @impl Phoenix.LiveView
  # coveralls-ignore-start - the same clause-head cover artifact; the
  # pagination test drives it and the body's lines carry counts
  def handle_event("load-more", _params, socket) do
    case Ash.page(socket.assigns.page, :next) do
      # coveralls-ignore-stop
      {:ok, page} ->
        # Exhaustion is uniform here: an empty last page appends nothing
        # and retires the button (more? false).
        {:noreply,
         socket
         |> stream(:entries, page.results, at: -1)
         |> assign(page: page)}

      # defensive: DB read failure between render and click — not
      # simulatable under the sandbox; the next click retries.
      # coveralls-ignore-start
      {:error, reason} ->
        require Logger

        Logger.error("Ledger page load failed: #{inspect(reason)}")
        {:noreply, socket}
        # coveralls-ignore-stop
    end
  end

  defp attempt_reverse(socket, admin, entry) do
    case Ash.get(LedgerEntry, entry.id, actor: admin) do
      {:ok, fresh} ->
        case Billing.reverse_entry(fresh) do
          {:ok, reversal} ->
            {:noreply, reversed(socket, fresh, reversal)}

          {:error, :already_reversed} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               gettext("That entry is already reversed. The ledger is refreshed.")
             )
             |> refresh_ledger()}

          # defensive: the posting only fails on a DB failure (the
          # double-reversal guard ran; the unique index backstops the
          # race) — not simulatable under the sandbox
          # coveralls-ignore-start
          {:error, _refused} ->
            {:noreply, reverse_refused(socket)}
            # coveralls-ignore-stop
        end

      # Ledger rows are never deleted (append-only), so this arm is
      # the DB-down class — not simulatable under the sandbox.
      # coveralls-ignore-start
      {:error, _vanished} ->
        {:noreply, reverse_refused(socket)}
        # coveralls-ignore-stop
    end
  end

  # -- reads ----------------------------------------------------------------

  defp ledger_page(wallet_id, admin) do
    LedgerEntry
    |> Ash.Query.for_read(:list_for_wallet, %{wallet_id: wallet_id}, actor: admin)
    |> Ash.Query.sort(created_at: :desc, id: :desc)
    |> Ash.read!(page: [limit: @page_size])
  end

  # The flagged lookup seam (Organization :admin_lookup) — the same one
  # read the table rides; a wallet's org exists while the FK stands.
  defp org_lookup(admin, ids) do
    {:ok, orgs} =
      Organization
      |> Ash.ActionInput.for_action(:admin_lookup, %{ids: ids}, actor: admin)
      |> Ash.run_action()

    {:ok, orgs}
  end

  # Post-write facts refresh: the balance and the runway projection move
  # with every posted row. Wallet rows are never deleted, so the plain
  # match is the DB-down class by construction.
  defp refresh_facts(socket) do
    admin = socket.assigns.current_user
    {:ok, wallet} = Ash.get(Wallet, socket.assigns.wallet.id, actor: admin)
    {:ok, runway} = Billing.compute_runway(wallet)

    assign(socket, wallet: wallet, runway: runway)
  end

  # A changed ledger re-reads page one and resets the stream: the same
  # honest-refresh posture as the people surface.
  defp refresh_ledger(socket) do
    admin = socket.assigns.current_user
    page = ledger_page(socket.assigns.wallet.id, admin)

    socket
    |> assign(
      page: page,
      ledger_empty?: page.results == [],
      reversed_ids: reversed_ids(page.results),
      confirm: nil
    )
    |> stream(:entries, page.results, reset: true)
  end

  defp reversed(socket, original, reversal) do
    socket
    |> put_flash(
      :info,
      gettext("Posted the compensating reversal. The original entry stays in the ledger.")
    )
    |> assign(
      confirm: nil,
      reversed_ids: MapSet.put(socket.assigns.reversed_ids, original.id)
    )
    |> refresh_facts()
    |> stream_insert(:entries, original)
    |> stream_insert(:entries, reversal, at: 0)
  end

  # coveralls-ignore-start - the demotion-window arm above
  defp reverse_refused(socket) do
    socket
    |> put_flash(:error, gettext("The reversal was refused. The ledger is refreshed."))
    |> refresh_ledger()
  end

  # coveralls-ignore-stop

  # -- input ----------------------------------------------------------------

  # A whole number of US cents, at least 1. Trailing junk ("5.50") is
  # refused, not truncated.
  defp parse_cents(raw) do
    trimmed = String.trim(raw || "")

    case Integer.parse(trimmed) do
      {cents, ""} when cents >= 1 -> {:ok, cents}
      _not_a_whole_positive -> :error
    end
  end

  # -- copy -----------------------------------------------------------------

  defp amount_invalid_copy do
    gettext("Enter a whole number of US cents, at least 1. Nothing was posted.")
  end

  defp goodwill_posted_copy(cents) do
    gettext(
      "Posted %{amount} as an adjustment credit. It sits at the top of the ledger. It cannot be un-posted, only reversed.",
      amount: AdminComponents.money_text(cents)
    )
  end

  defp waiver_flash(true) do
    gettext(
      "The paywall gate is waived for this org. Private access and backups are unlocked. No money moved."
    )
  end

  defp waiver_flash(false) do
    gettext(
      "The waiver is removed. The has-paid gate is closed again. Private access and backups lock until the org tops up."
    )
  end

  defp waiver_title(true, org_name) do
    gettext("Waive the paywall gate for %{org}?", org: org_name)
  end

  defp waiver_title(false, org_name) do
    gettext("Remove the paywall waiver for %{org}?", org: org_name)
  end

  # The contract, in the confirm where the click happens: what the
  # waiver does, and what it never does. Removing names what closes.
  defp waiver_body(true) do
    gettext(
      "The waiver satisfies only the has-paid gate. It unlocks private access and backups for this org. It moves no money, posts no ledger row, and waives nothing spendable."
    )
  end

  defp waiver_body(false) do
    gettext(
      "The has-paid gate closes again. Private access and backups lock until the org tops up. No money moves."
    )
  end

  defp waiver_action(true), do: gettext("Yes, waive the gate")
  defp waiver_action(false), do: gettext("Yes, remove the waiver")

  # Reached only under the match? guard in the template.
  defp waiver_target({:waiver, target}), do: target

  defp flip_label(true), do: gettext("Remove the waiver")
  defp flip_label(false), do: gettext("Waive the gate")

  defp waiver_tone(true), do: "primary"
  defp waiver_tone(false), do: "neutral"

  defp waiver_label(true), do: gettext("Waived")
  defp waiver_label(false), do: gettext("Not waived")

  defp reverse_title(entry) do
    gettext("Reverse the %{amount} credit?",
      amount: AdminComponents.ledger_amount_text(entry.amount)
    )
  end

  # -- display helpers ------------------------------------------------------

  defp destroy_clock?(runway, wallet) do
    runway.balance_cents < 0 or not is_nil(wallet.negative_since)
  end

  # Reached only under the negative_since guard in the template.
  defp stamp_text(stamp), do: Calendar.strftime(stamp, "%b %d, %Y")

  # Only a credit that is not itself a reversal, and has no reversal in
  # the loaded window, offers the lever. A reversal parked on a later
  # page still shows it, and the domain's own guard answers the click —
  # the honest refresh is the fallback either way.
  defp reversible?(entry, reversed_ids) do
    entry.type == :credit and is_nil(entry.reverses_id) and
      not MapSet.member?(reversed_ids, entry.id)
  end

  defp reversing?(entry, {:reverse, opened}), do: entry.id == opened.id
  defp reversing?(_entry, _other), do: false

  defp reversed_ids(entries) do
    entries
    |> MapSet.new(& &1.reverses_id)
    |> MapSet.delete(nil)
  end

  # Distinct tone-and-shape pairs (the people surface's badge grammar):
  # no two reasons ever share both tone and icon, in either theme.
  defp reason_tone(:welcome), do: "primary"
  defp reason_tone(:purchase), do: "success"
  defp reason_tone(:usage), do: "neutral"
  defp reason_tone(:refund), do: "primary"
  defp reason_tone(:adjustment), do: "warning"

  defp reason_icon(:welcome), do: "hero-sparkles"
  defp reason_icon(:purchase), do: "hero-credit-card"
  defp reason_icon(:usage), do: "hero-cpu-chip"
  defp reason_icon(:refund), do: "hero-arrow-path"
  defp reason_icon(:adjustment), do: "hero-adjustments-horizontal"

  defp reason_label(:welcome), do: gettext("Welcome credit")
  defp reason_label(:purchase), do: gettext("Purchase")
  defp reason_label(:usage), do: gettext("Usage")
  defp reason_label(:refund), do: gettext("Refund")
  defp reason_label(:adjustment), do: gettext("Adjustment")

  defp amount_color(:credit), do: "text-success"
  defp amount_color(:debit), do: "text-danger"

  # The posting's provenance, read-only: the provider-prefixed
  # idempotency key (polar:<checkout>, the webhook's second lock) or
  # the accrual subject. Both nullable, nothing minted for display.
  defp reference_text(entry), do: entry.idempotency_key || entry.subject

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      actor_orgs={@actor_orgs}
      personal_org_id={@personal_org_id}
      username={@username}
      nav_section={@nav_section}
      bare
    >
      <div class="appgram contents" data-testid="admin-wallet-detail">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5">{@org.name}</h1>
              <p class="mt-2 max-w-prose text-base text-ink-muted">
                {gettext("The wallet behind %{org}. Balance, runway, and the ledger.", org: @org.name)}
              </p>
              <div class="mt-4">
                <.link
                  navigate={~p"/admin/billing"}
                  data-testid="admin-wallet-back-link"
                  class="text-sm font-medium text-link underline-offset-2 hover:underline"
                >
                  {gettext("Back to wallets")}
                </.link>
              </div>

              <div class="mt-9">
                <BillingComponents.wallet_facts facts={@runway} />
              </div>
            </div>
          </div>
        </section>

        <%!-- The destroy clock's honest gravity: a negative balance is
        a countdown to data deletion, and the card says exactly what
        the ladder does. --%>
        <section class="wrap pt-2 pb-8">
          <div
            :if={destroy_clock?(@runway, @wallet)}
            class="rise rounded-panel border border-line-danger bg-danger-muted px-4 py-3"
            data-testid="admin-wallet-destroy-clock"
          >
            <p class="text-sm font-semibold text-danger">
              {gettext("The balance is below zero.")}
            </p>
            <p class="mt-1 text-sm text-ink">
              <%= if @wallet.negative_since do %>
                {gettext(
                  "The org's instances are stopped and its data is on a destroy clock: deletion lands 30 days after %{date}, the day the balance first went negative. A top-up that restores the balance clears the clock.",
                  date: stamp_text(@wallet.negative_since)
                )}
              <% else %>
                {gettext(
                  "The org's instances are stopped. The destroy clock starts at the next automatic check. A top-up that restores the balance clears everything."
                )}
              <% end %>
            </p>
          </div>
        </section>

        <section class="wrap pt-4 pb-8">
          <div class="rise grid items-start gap-6 lg:grid-cols-2">
            <%!-- The waiver card: the contract in plain copy, the flip
            confirmed inline where the toggle lives. --%>
            <.card class="space-y-4" data-testid="admin-wallet-waiver-card">
              <div class="flex items-start justify-between gap-4">
                <div class="min-w-0">
                  <h2 class="text-base font-medium text-ink">{gettext("Paywall waiver")}</h2>
                  <p class="mt-1 text-sm text-ink-muted">
                    {gettext(
                      "The waiver satisfies only the has-paid gate. It unlocks private access and backups for this org. It moves no money, posts no ledger row, and waives nothing spendable."
                    )}
                  </p>
                </div>
                <span class="shrink-0" data-testid="admin-wallet-waiver-state">
                  <.badge tone={waiver_tone(@wallet.paywall_waived)}>
                    <.icon :if={@wallet.paywall_waived} name="hero-key" class="size-3.5" />
                    {waiver_label(@wallet.paywall_waived)}
                  </.badge>
                </span>
              </div>
              <.button
                variant="secondary"
                phx-click="open-waiver"
                phx-disable-with={gettext("Opening...")}
                data-testid="admin-wallet-waiver-flip"
              >
                {flip_label(@wallet.paywall_waived)}
              </.button>

              <div :if={match?({:waiver, _}, @confirm)}>
                <.confirm_block
                  title={waiver_title(waiver_target(@confirm), @org.name)}
                  body={waiver_body(waiver_target(@confirm))}
                  action={waiver_action(waiver_target(@confirm))}
                  event="confirm-waiver"
                  action_testid="admin-wallet-waiver-confirm"
                  cancel_testid="admin-wallet-waiver-cancel"
                  myself={nil}
                />
              </div>
            </.card>

            <%!-- The goodwill credit: the keyless post's fence is the
            button, the consequence is the copy, and the guard is the
            posted row at the top of the ledger. --%>
            <.card class="space-y-4" data-testid="admin-wallet-goodwill-card">
              <div>
                <h2 class="text-base font-medium text-ink">{gettext("Goodwill credit")}</h2>
                <p class="mt-1 text-sm text-ink-muted">
                  {gettext(
                    "Posts immediately as an adjustment credit. A post cannot be undone, only reversed with a compensating entry. Each submit posts, so submit once."
                  )}
                </p>
              </div>
              <.form
                for={@goodwill_form}
                id="admin-wallet-goodwill-form"
                phx-submit="grant-goodwill"
                class="space-y-4"
              >
                <.input
                  field={@goodwill_form[:amount_cents]}
                  type="number"
                  min="1"
                  step="1"
                  label={gettext("Amount (US cents)")}
                  data-testid="admin-wallet-goodwill-amount"
                />
                <.button
                  type="submit"
                  phx-disable-with={gettext("Posting...")}
                  data-testid="admin-wallet-goodwill-submit"
                >
                  {gettext("Post credit")}
                </.button>
              </.form>
            </.card>
          </div>
        </section>

        <section class="wrap pt-4 pb-16">
          <div class="rise space-y-4" data-testid="admin-wallet-ledger-section">
            <h2 class="text-lg font-semibold tracking-tight text-ink">{gettext("Ledger")}</h2>

            <.card>
              <p
                :if={@ledger_empty?}
                class="text-sm text-ink-subtle"
                data-testid="admin-wallet-ledger-empty"
              >
                {gettext("No activity yet.")}
              </p>

              <div id="admin-wallet-ledger" phx-update="stream">
                <div
                  :for={{dom_id, entry} <- @streams.entries}
                  id={dom_id}
                  data-testid={"admin-wallet-entry-#{entry.id}"}
                  class="border-t border-line py-3 first:border-t-0"
                >
                  <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
                    <span class="whitespace-nowrap font-mono text-xs text-ink-muted">
                      {Calendar.strftime(entry.created_at, "%b %d, %Y %H:%M UTC")}
                    </span>
                    <span class="flex flex-wrap items-center gap-1.5">
                      <.badge tone={reason_tone(entry.reason)}>
                        <.icon name={reason_icon(entry.reason)} class="size-3.5" />
                        {reason_label(entry.reason)}
                      </.badge>
                      <.badge :if={entry.reverses_id} tone="danger">
                        <.icon name="hero-arrow-uturn-left" class="size-3.5" />
                        {gettext("Reversal")}
                      </.badge>
                      <.badge :if={MapSet.member?(@reversed_ids, entry.id)} tone="neutral">
                        <.icon name="hero-arrow-uturn-right" class="size-3.5" />
                        {gettext("Reversed")}
                      </.badge>
                    </span>
                    <span
                      class={[
                        "whitespace-nowrap font-mono text-sm",
                        amount_color(entry.type)
                      ]}
                      data-testid={"admin-wallet-amount-#{entry.id}"}
                    >
                      {AdminComponents.ledger_amount_text(entry.amount)}
                    </span>
                    <span
                      class="min-w-0 max-w-[12rem] truncate font-mono text-xs text-ink-muted"
                      title={reference_text(entry)}
                      data-testid={"admin-wallet-reference-#{entry.id}"}
                    >
                      {reference_text(entry)}
                    </span>
                    <.button
                      :if={reversible?(entry, @reversed_ids)}
                      size="sm"
                      variant="secondary"
                      phx-click="open-reverse"
                      phx-value-id={entry.id}
                      phx-disable-with={gettext("Opening...")}
                      data-testid={"admin-wallet-reverse-#{entry.id}"}
                    >
                      {gettext("Reverse")}
                    </.button>
                  </div>

                  <%!-- The confirm expands directly under the row that
                  opened it; one confirm per page (@confirm is the
                  expansion key), so the shared destructive-confirm
                  testid stays safe. --%>
                  <div :if={reversing?(entry, @confirm)} class="pt-3">
                    <.confirm_block
                      title={reverse_title(entry)}
                      body={
                        gettext(
                          "A compensating debit is posted for the same amount. The original entry stays in the ledger. Net effect on the balance: zero."
                        )
                      }
                      action={gettext("Yes, reverse this entry")}
                      event="confirm-reverse"
                      action_testid="admin-wallet-reverse-confirm"
                      cancel_testid="admin-wallet-reverse-cancel"
                      myself={nil}
                    />
                  </div>
                </div>
              </div>

              <div class="mt-4">
                <.button
                  :if={@page.more?}
                  id="admin-wallet-load-more"
                  variant="ghost"
                  size="sm"
                  phx-click="load-more"
                  data-testid="admin-wallet-load-more"
                >
                  {gettext("Load more")}
                </.button>
              </div>
            </.card>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
