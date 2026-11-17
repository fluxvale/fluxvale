defmodule FluxValeWeb.BillingLive.Index do
  @moduledoc """
  The billing surface (#123): the org wallet's facts and paginated
  ledger history. The band's Balance/Runway facts ride the
  `Billing.compute_runway/1` projection (the dashboard's source — one
  wallet story for both surfaces); history is keyset-paginated
  newest-first, appended into the stream by "Load more" — cursors
  survive rows landing between pages, offset windows wouldn't.

  "Top up wallet" opens the top-up wizard (#137). No live updates:
  facts read at mount; the wizard's confirmation refreshes on its
  own navigation. The band facts, the ledger history, and the
  auto-recharge card (#829 L3) render through BillingComponents —
  shared with the org billing view (#276).
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts
  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxValeWeb.BillingComponents

  @page_size 25

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    case Accounts.personal_org_for_user(user.id, actor: user) do
      {:ok, org} ->
        # ensure_wallet is the system seam (idempotent); the facts ride
        # the runway projection (balance included — the dashboard's
        # source), the ledger read runs against the actor through the
        # wallet policies.
        {:ok, wallet} = Billing.ensure_wallet(org)
        {:ok, runway} = Billing.compute_runway(wallet)

        page = ledger_page(wallet.id, user)

        socket =
          socket
          |> stream(:entries, page.results)
          |> assign(
            wallet: wallet,
            runway: runway,
            page: page,
            history_empty?: page.results == []
          )
          |> assign_auto_recharge(org, user)

        {:ok, socket}

      :none ->
        # Unreachable for action-created users (JIT org provisioning);
        # a seeded/legacy row without an org lands here.
        {:ok,
         socket
         |> put_flash(:error, "No organization found for this account.")
         |> push_navigate(to: ~p"/apps")}
    end
  end

  @impl Phoenix.LiveView
  # Single-clause def with a literal head pattern: OTP cover's entry
  # counter for this shape never fires (the body lines carry the hits) —
  # same artifact class as the defguard exclusion in DebitWallet.
  # coveralls-ignore-next-line
  def handle_event("load-more", _params, socket) do
    case Ash.page(socket.assigns.page, :next) do
      {:ok, page} ->
        # Exhaustion is uniform here: an empty last page appends nothing
        # and retires the button (more? false).
        {:noreply,
         socket
         |> stream(:entries, page.results, at: -1)
         |> assign(:page, page)}

      {:error, reason} ->
        # defensive: DB read failure between render and click — not
        # simulatable under the sandbox; the next click retries.
        # coveralls-ignore-start
        require Logger

        Logger.error("Ledger page load failed: #{inspect(reason)}")
        {:noreply, socket}
        # coveralls-ignore-stop
    end
  end

  @impl Phoenix.LiveView
  # The card's phx-change round-trip: keep what the owner typed in the
  # form (the inputs re-render from this assign after a failed save).
  # is_map: a crafted non-map payload is a no-op, never a crash (the
  # hostile-push silence posture).
  def handle_event("validate-auto-recharge", %{"auto_recharge" => params}, socket)
      when is_map(params) do
    {:noreply, assign(socket, auto_recharge_form: to_form(params, as: :auto_recharge))}
  end

  def handle_event("validate-auto-recharge", _crafted_shape, socket) do
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  # The owner's save, through the domain seam (Billing.
  # set_auto_recharge_setting — never the resource direct): the enum,
  # the constraints, the AutoArmGate, and the owner-role policy are the
  # authority, so a crafted `:auto` and a member's crafted submit land
  # here as an error flash, never a crash. is_map: a crafted non-map
  # payload is a no-op, never a crash.
  def handle_event("save-auto-recharge", %{"auto_recharge" => params}, socket)
      when is_map(params) do
    case auto_recharge_inputs(params) do
      {:ok, inputs} ->
        case Billing.set_auto_recharge_setting(
               socket.assigns.auto_recharge_setting,
               inputs,
               actor: socket.assigns.current_user
             ) do
          {:ok, setting} ->
            {:noreply,
             socket
             |> put_flash(:info, "Reminder settings saved.")
             |> assign(auto_recharge_setting: setting)
             |> assign(auto_recharge_form: prefilled_auto_recharge_form(setting, true))}

          {:error, _rejected_by_the_domain} ->
            {:noreply, failed_auto_recharge_save(socket, params, default_auto_recharge_error())}
        end

      {:error, message} ->
        {:noreply, failed_auto_recharge_save(socket, params, message)}
    end
  end

  def handle_event("save-auto-recharge", _crafted_shape, socket) do
    {:noreply, socket}
  end

  # The card's prefilled form: whole dollars, the wizard Amount step's
  # unit. A non-owner gets no form (nil) — the card renders the
  # read-only state alone. The nil clause is unreachable HERE (this
  # surface's org is the actor's personal one, whose only seat is the
  # owner's); it keeps the helper total, mirroring the org page's
  # (covered by that surface's member test).
  # coveralls-ignore-next-line
  defp prefilled_auto_recharge_form(_setting, false = _owner?), do: nil

  defp prefilled_auto_recharge_form(setting, true) do
    to_form(
      %{
        "mode" => Atom.to_string(setting.mode),
        "threshold_dollars" => prefilled_dollars(setting.threshold_cents),
        "amount_dollars" => prefilled_dollars(setting.amount_cents)
      },
      as: :auto_recharge
    )
  end

  # Whole-round values prefill their dollar figure. A non-round stored
  # value (549¢) MUST NOT prefill "5": an unedited save would silently
  # floor it to 500¢ while the state copy still says $5.49. Those
  # prefill EMPTY — the card's inline hint names the stored exact
  # value, and the whole-dollar validation refuses the empty save.
  defp prefilled_dollars(cents) do
    if rem(cents, 100) == 0 do
      dollars = div(cents, 100)
      Integer.to_string(dollars)
    else
      ""
    end
  end

  # The card's server-side mirror of the resource's constraints (#829
  # L1): threshold ≥ $1 (the attribute constraint's floor in the form's
  # whole-dollar unit), amount ≥ the wizard's floor
  # (Billing.min_topup_dollars/0 — the same unit the one-click link
  # pre-fills). Mode rides as the typed string: the enum and the
  # AutoArmGate are the authority — a crafted `:auto` is refused by the
  # domain, not by this card.
  defp auto_recharge_inputs(params) do
    min_dollars = Billing.min_topup_dollars()

    with {:ok, threshold} <-
           whole_dollars(params["threshold_dollars"], 1, threshold_error()),
         {:ok, amount} <-
           whole_dollars(params["amount_dollars"], min_dollars, amount_error()) do
      {:ok,
       %{
         mode: params["mode"],
         threshold_cents: threshold * 100,
         amount_cents: amount * 100
       }}
    end
  end

  defp whole_dollars(raw, min, message) when is_binary(raw) do
    trimmed = String.trim(raw)

    case Integer.parse(trimmed) do
      {dollars, ""} when dollars >= min -> {:ok, dollars}
      _not_a_whole_dollar_at_or_above_the_min -> {:error, message}
    end
  end

  defp whole_dollars(_missing_or_malformed, _min, message), do: {:error, message}

  defp failed_auto_recharge_save(socket, params, message) do
    socket
    |> put_flash(:error, message)
    |> assign(auto_recharge_form: to_form(params, as: :auto_recharge))
  end

  defp default_auto_recharge_error,
    do: "Couldn't save the reminder settings. Check the values and try again."

  defp threshold_error, do: "The threshold must be a whole-dollar amount of at least $1."

  defp amount_error do
    "The amount must be a whole-dollar amount of at least $#{Billing.min_topup_dollars()}."
  end

  # The auto-recharge card's assigns (#829 L3): the row ensured at
  # mount — the owner's first write is `:set`, an UPDATE that cannot
  # run on a nil row, so the page provisions through the system seam
  # (`Billing.ensure_auto_recharge_setting`, the EnsureWallet shape).
  # The form gate is the write policy's own ownership check — UX only;
  # the domain seam is the authority. The org billing page mirrors this
  # wiring on purpose: each surface owns its private helpers, only the
  # markup is shared (BillingComponents.auto_recharge_card). On this
  # surface the actor is their personal org's owner, so the form is
  # the expected shape — the gate still computes, never assumes.
  defp assign_auto_recharge(socket, org, user) do
    {:ok, setting} = Billing.ensure_auto_recharge_setting(org)
    owner? = ActorIsOrganizationOwner.owner?(user, org)

    socket
    |> assign(auto_recharge_setting: setting, auto_recharge_owner?: owner?)
    |> assign(auto_recharge_form: prefilled_auto_recharge_form(setting, owner?))
  end

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
      <%!-- App-wide grammar page (S9): `bare` main + .appgram — the page
      owns ALL of main's rhythm. The sunken band is the wallet: title +
      CTA on the S6 band shape, the facts as eyebrow-labeled values
      (the S4/S6 in-band posture, NOT floating stat cards), and the
      top-up notice as the band's small print. No straddle (the one
      straddle stays the instance show's, per S4's verdict). --%>
      <div class="appgram contents">
        <%!-- 1. The wallet band. --%>
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <div class="flex flex-wrap items-end justify-between gap-x-6 gap-y-4">
                <div class="min-w-0">
                  <p class="eyebrow">Wallet</p>
                  <h1 class="page-title mt-1.5">Billing</h1>
                  <p class="mt-2 text-base text-ink-muted">
                    Your prepaid wallet funds your instances.
                  </p>
                </div>

                <div class="flex shrink-0 gap-2">
                  <.button navigate={~p"/billing/topup"} variant="secondary" id="add-credits">
                    Top up wallet
                  </.button>
                </div>
              </div>

              <div class="mt-9">
                <BillingComponents.wallet_facts facts={@runway} />
              </div>

              <p class="mt-6 text-xs text-ink-subtle" data-testid="topup-notice">
                Wallet balance can be used for any app, never expires, and is non-refundable. See the <.link
                  navigate={~p"/policies/refund"}
                  data-testid="topup-refund-policy"
                  class="underline underline-offset-2 hover:text-ink"
                >
                  refund policy
                </.link>.
              </p>
            </div>
          </div>
        </section>

        <%!-- 2. The auto-recharge card (#829 L3): between the band and
        the ledger. The container-level rise rides a node no patch
        replaces (the ledger's measured pattern). --%>
        <section aria-label="Auto-recharge" class="wrap pt-10">
          <div class="rise [animation-delay:120ms]">
            <BillingComponents.auto_recharge_card
              setting={@auto_recharge_setting}
              owner?={@auto_recharge_owner?}
              form={@auto_recharge_form}
            />
          </div>
        </section>

        <%!-- 3. The ledger — the S4/S6 section shape: heading outside the
        card, container-level rise (the stream patches rewrite rows in
        place; a rise on patched nodes would replay the reveal — node
        identity is what the rise rides). --%>
        <section aria-labelledby="billing-history-title" class="wrap pt-10 pb-16">
          <div class="rise space-y-4 [animation-delay:170ms]">
            <h2 id="billing-history-title" class="text-lg font-semibold tracking-tight text-ink">
              History
            </h2>

            <BillingComponents.ledger_history
              entries={@streams.entries}
              page={@page}
              history_empty?={@history_empty?}
            />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp ledger_page(wallet_id, user) do
    LedgerEntry
    |> Ash.Query.for_read(:list_for_wallet, %{wallet_id: wallet_id}, actor: user)
    |> Ash.Query.sort(created_at: :desc, id: :desc)
    |> Ash.read!(page: [limit: @page_size])
  end
end
