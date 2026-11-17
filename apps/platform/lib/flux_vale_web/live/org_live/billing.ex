defmodule FluxValeWeb.OrganizationLive.Billing do
  @moduledoc """
  The org billing view (#276): the `/billing` surface — balance and
  paginated ledger — scoped to the URL's org instead of the actor's
  personal one. Slug-keyed mount like the catalog; unknown slugs and
  policy denials read as "not here" — one arm, one answer, so a
  non-member's probe is indistinguishable from a typo (no enumeration).

  The band's Top up wallet CTA opens the org-scoped top-up wizard
  (#408): a top-up credits the URL org's wallet. The auto-recharge
  card (#829 L3, the launch shape — reminders only) mounts between
  the band and the ledger, the personal page's shape over this
  URL-resolved org; owners set it, members read it. The personal org
  has no view here at all (S5): its URL redirects to `/billing` — one
  wallet, one surface.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxValeWeb.BillingComponents
  alias FluxValeWeb.PersonalOrg

  # Mirrors BillingLive.Index — same read, same window; the pages differ
  # only in which org they resolved.
  @page_size 25

  @impl Phoenix.LiveView
  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Organization.get_by_slug(slug, actor: user) do
      {:ok, org} ->
        if PersonalOrg.personal?(socket, org) do
          # S5: no separate balance view for the personal org — its
          # wallet IS /billing. Flash-free redirect (nothing failed).
          {:ok, push_navigate(socket, to: ~p"/billing")}
        else
          mount_org_billing(socket, org, user)
        end

      _error ->
        # The member-scoped read policy filters an unknown slug and a
        # non-member's target to the same nothing.
        {:ok,
         socket
         |> put_flash(:error, "Organization not found.")
         |> push_navigate(to: ~p"/")}
    end
  end

  defp mount_org_billing(socket, org, user) do
    # ensure_wallet is the system seam (idempotent); the facts ride the
    # runway projection (balance included — the dashboard's source, the
    # personal page's posture), the org resolved from the URL.
    {:ok, wallet} = Billing.ensure_wallet(org)
    {:ok, runway} = Billing.compute_runway(wallet)

    page = ledger_page(wallet.id, user)

    socket =
      socket
      |> stream(:entries, page.results)
      |> assign(
        org: org,
        wallet: wallet,
        runway: runway,
        page: page,
        history_empty?: page.results == []
      )
      |> assign_auto_recharge(org, user)

    {:ok, socket}
  end

  # The auto-recharge card's assigns (#829 L3): the row ensured at
  # mount — the owner's first write is `:set`, an UPDATE that cannot
  # run on a nil row, so the page provisions through the system seam
  # (`Billing.ensure_auto_recharge_setting`, the EnsureWallet shape).
  # The form gate is the write policy's own ownership check — UX only;
  # the domain seam is the authority. The personal billing page mirrors
  # this wiring on purpose: each surface owns its private helpers, only
  # the markup is shared (BillingComponents.auto_recharge_card).
  defp assign_auto_recharge(socket, org, user) do
    {:ok, setting} = Billing.ensure_auto_recharge_setting(org)
    owner? = ActorIsOrganizationOwner.owner?(user, org)

    socket
    |> assign(auto_recharge_setting: setting, auto_recharge_owner?: owner?)
    |> assign(auto_recharge_form: prefilled_auto_recharge_form(setting, owner?))
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
  # unit. Members get no form (nil) — the card renders the read-only
  # state alone.
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
      current_org={@org}
      bare
    >
      <%!-- App-wide grammar page (S9): `bare` main + .appgram — the page
      owns ALL of main's rhythm. The band is the org's wallet: the org's
      name rides the band's eyebrow (the S6 identity posture, no second
      mark block), the h1 stays "Billing" — the heading outline never
      collides with the org home's (the S8 muted-prefix lesson, avoided
      outright). No straddle. --%>
      <div class="appgram contents">
        <%!-- 1. The org wallet band. --%>
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <%!-- The band shape the personal billing page set (S9):
              identity left, the top-up CTA right — the wizard it
              opens bills THIS org's wallet (#408). --%>
              <div class="flex flex-wrap items-end justify-between gap-x-6 gap-y-4">
                <div class="min-w-0">
                  <p class="eyebrow">{@org.name}</p>
                  <h1 class="page-title mt-1.5">Billing</h1>
                  <p class="mt-2 text-base text-ink-muted">
                    A prepaid wallet funds {@org.name}'s instances.
                  </p>
                </div>

                <div class="flex shrink-0 gap-2">
                  <.button
                    navigate={~p"/organizations/#{@org.slug}/billing/topup"}
                    variant="secondary"
                    id="add-credits"
                  >
                    Top up wallet
                  </.button>
                </div>
              </div>

              <div class="mt-9">
                <BillingComponents.wallet_facts facts={@runway} />
              </div>
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

        <%!-- 3. The ledger — the S4/S6 section shape (the personal
        page's posture): heading outside the card, container-level rise
        (stream patches rewrite rows in place; node identity is what
        the rise rides). --%>
        <section aria-labelledby="org-billing-history-title" class="wrap pt-10 pb-16">
          <div class="rise space-y-4 [animation-delay:170ms]">
            <h2 id="org-billing-history-title" class="text-lg font-semibold tracking-tight text-ink">
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
