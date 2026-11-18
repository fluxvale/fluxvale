defmodule FluxValeWeb.OrganizationLive.Billing do
  @moduledoc """
  The org billing view (#276): the `/billing` surface — balance and
  paginated ledger — scoped to the URL's org instead of the actor's
  personal one. Slug-keyed mount like the catalog; unknown slugs and
  policy denials read as "not here" — one arm, one answer, so a
  non-member's probe is indistinguishable from a typo (no enumeration).

  The band's Top up wallet CTA opens the org-scoped top-up wizard
  (#408): a top-up credits the URL org's wallet. The auto-recharge
  card (#829 L3 launch shape, S5 staged charge presentation) mounts
  between the band and the ledger, the personal page's shape over this
  URL-resolved org; owners set it, members read it. Everything chargey
  renders only gate-on (`Billing.auto_recharge_charge_mode?/0`): the
  mount syncs the saved-method state, the "Add payment method" click
  mints a FRESH portal session per click, and arming `:auto` is its
  own confirmed action. The personal org has no view here at all
  (S5): its URL redirects to `/billing` — one wallet, one surface.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Topup
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxValeWeb.BillingComponents
  alias FluxValeWeb.PersonalOrg

  require Ash.Query

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

  # The auto-recharge card's assigns (#829 L3, extended by S5): the row
  # ensured at mount — the owner's first write is `:set`, an UPDATE
  # that cannot run on a nil row, so the page provisions through the
  # system seam (`Billing.ensure_auto_recharge_setting`, the EnsureWallet
  # shape). The form gate is the write policy's own ownership check —
  # UX only; the domain seam is the authority. Gate-on the mount also
  # syncs the saved-method state (one cheap provider GET — the poll IS
  # the sync; Polar has no method-attached webhook), reads the last 3
  # `:auto` top-ups, and resolves the evidence defaults; gate-off
  # ZERO charge-lane work happens — no sync, no reads, the launch
  # shape. The personal billing page mirrors this wiring on purpose:
  # each surface owns its private helpers, only the markup is shared
  # (BillingComponents.auto_recharge_card).
  defp assign_auto_recharge(socket, org, user) do
    {:ok, ensured} = Billing.ensure_auto_recharge_setting(org)
    owner? = ActorIsOrganizationOwner.owner?(user, org)
    charge_mode? = Billing.auto_recharge_charge_mode?()
    setting = if charge_mode?, do: synced_setting(ensured), else: ensured

    socket
    |> assign(
      auto_recharge_setting: setting,
      auto_recharge_owner?: owner?,
      charge_mode?: charge_mode?,
      arm_confirm?: false,
      auto_topups: if(charge_mode?, do: recent_auto_topups(org, user), else: [])
    )
    |> assign(
      auto_recharge_form: prefilled_auto_recharge_form(setting, owner?, org, user, charge_mode?)
    )
  end

  # Gate-on with a stored provider customer: the sync's fresh row wins.
  # A provider error leaves the stored row untouched — the next mount
  # retries (never flip a status on a fault).
  defp synced_setting(setting) do
    case Billing.sync_payment_method(setting) do
      {:ok, _status, fresh} -> fresh
      {:error, _provider_or_gate} -> setting
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
    {:noreply, assign(socket, auto_recharge_form: auto_recharge_form(params))}
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
  #
  # Arming :auto is its own CONFIRMED action (decision G): a save
  # carrying the :auto choice never writes — it opens the confirm
  # step, whose copy names the gross math; the confirm event is the
  # write. Owner-only here too: a member's crafted :auto submit rides
  # the normal path into the domain's refusal (the L3 discipline).
  def handle_event("save-auto-recharge", %{"auto_recharge" => params}, socket)
      when is_map(params) do
    if arming?(socket, params) do
      stage_arm(socket, params)
    else
      save_auto_recharge(socket, params)
    end
  end

  def handle_event("save-auto-recharge", _crafted_shape, socket) do
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  # The arming confirm (decision G): the ONLY event that writes :auto.
  # Requires the confirm state (opened by the save handler) and the
  # owner gate — a crafted confirm on a member's view, or without the
  # step, is silence, never a write.
  #
  # The write is BOUND to the terms the owner confirmed: the button
  # carries the snapshot it displayed (phx-values) and the handler
  # compares it to the CURRENT stored row — a second tab's save in
  # between refuses with a re-rendered confirm (the copy re-reads the
  # fresh row), never arms over unseen terms. The domain's AutoArmGate
  # stays the authority for the gate/method questions.
  def handle_event("confirm-arm-auto", params, socket) do
    if socket.assigns.charge_mode? and socket.assigns.auto_recharge_owner? and
         socket.assigns.arm_confirm? do
      confirm_arm(socket, params)
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("cancel-arm-auto", _params, socket) do
    {:noreply, assign(socket, arm_confirm?: false)}
  end

  @impl Phoenix.LiveView
  # The "Add payment method" click (S5): owner-only, gate-on — the
  # launch posture and a member's view make NO provider call; a crafted
  # event is silence. Success redirects OFF-SITE to the portal URL (the
  # wizard's practice) — the URL is FRESH per click, minted by the seam
  # and never stored.
  def handle_event("add-payment-method", _params, socket) do
    if Billing.auto_recharge_charge_mode?() and socket.assigns.auto_recharge_owner? do
      open_billing_session(socket)
    else
      {:noreply, socket}
    end
  end

  defp open_billing_session(socket) do
    case Billing.open_billing_session(
           socket.assigns.org,
           socket.assigns.auto_recharge_setting,
           socket.assigns.current_user
         ) do
      {:ok, portal_url} ->
        {:noreply, redirect(socket, external: portal_url)}

      # The evidence is the request's country — without it the provider
      # has nothing to tax against; the hint points at the settings.
      {:error, :billing_country_missing} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Add a billing country in the charge settings first — charges are taxed against it."
         )}

      {:error, _refused_by_the_seam} ->
        {:noreply,
         put_flash(socket, :error, "Couldn't open the payment portal. Try again in a moment.")}
    end
  end

  # The arming decision (decision G): gate-on, the owner, the :auto
  # choice, and a method attached — the last so the confirm only opens
  # when it can succeed (a methodless crafted :auto rides the normal
  # save path into the AutoArmGate's refusal, never a step that claims
  # a saved card).
  defp arming?(socket, params) do
    Billing.auto_recharge_charge_mode?() and params["mode"] == "auto" and
      socket.assigns.auto_recharge_setting.payment_method_status == :attached and
      socket.assigns.auto_recharge_owner?
  end

  # Save-and-stage: the form's dials + evidence persist as a NORMAL
  # modeless write first — the confirm step then displays the
  # just-stored terms and its binding compares against them. Mode is
  # NOT written here; the confirm event is the only `:auto` writer
  # (the AutoArmGate doesn't fire on a modeless save — it triggers on a
  # mode change — and arming? already required a method).
  defp stage_arm(socket, params) do
    case auto_recharge_inputs(params) do
      {:ok, inputs} ->
        case Billing.set_auto_recharge_setting(
               socket.assigns.auto_recharge_setting,
               Map.delete(inputs, :mode),
               actor: socket.assigns.current_user
             ) do
          {:ok, setting} ->
            {:noreply,
             socket
             |> assign(auto_recharge_setting: setting, arm_confirm?: true)
             |> assign(auto_recharge_form: post_save_auto_recharge_form(setting))}

          {:error, _rejected_by_the_domain} ->
            {:noreply, failed_auto_recharge_save(socket, params, default_auto_recharge_error())}
        end

      {:error, message} ->
        {:noreply, failed_auto_recharge_save(socket, params, message)}
    end
  end

  # The non-arming save path, through the domain seam (Billing.
  # set_auto_recharge_setting — never the resource direct): the enum,
  # the constraints, the AutoArmGate, and the owner-role policy are the
  # authority, so a crafted `:auto` and a member's crafted submit land
  # here as an error flash, never a crash. ANY non-arming save also
  # closes the arming confirm — the step must never outlive the owner's
  # latest choice (a stale confirm's click, its snapshot matching
  # unchanged terms, would otherwise arm `:auto` after the owner saved
  # something else).
  defp save_auto_recharge(socket, params) do
    socket = assign(socket, :arm_confirm?, false)

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
             |> assign(auto_recharge_form: post_save_auto_recharge_form(setting))}

          {:error, _rejected_by_the_domain} ->
            {:noreply, failed_auto_recharge_save(socket, params, default_auto_recharge_error())}
        end

      {:error, message} ->
        {:noreply, failed_auto_recharge_save(socket, params, message)}
    end
  end

  # The binding: the button's snapshot (phx-values, binaries) compared
  # to the CURRENT stored row. Crafted garbage refuses the same way —
  # the safe direction.
  defp confirm_arm(socket, params) do
    case Billing.get_auto_recharge_setting(socket.assigns.org.id, authorize?: false) do
      {:ok, fresh} ->
        if terms_match?(fresh, params) do
          arm_confirmed(socket, fresh)
        else
          # Stale terms — the row moved under the confirm. Re-render the
          # step from the fresh row so the next click's snapshot carries
          # the new values.
          {:noreply,
           socket
           |> put_flash(:error, "The charge settings changed — review them and confirm again.")
           |> assign(auto_recharge_setting: fresh)
           |> assign(auto_recharge_form: post_save_auto_recharge_form(fresh))}
        end

      # defensive: the row vanished between the confirm render and the
      # click (no path deletes setting rows) — close the step, never crash.
      # coveralls-ignore-start
      {:error, _row_gone} ->
        {:noreply,
         socket
         |> put_flash(:error, "The charge settings changed — review them and confirm again.")
         |> assign(arm_confirm?: false)}

        # coveralls-ignore-stop
    end
  end

  # The terms matched — the arm write, bound to exactly what the owner
  # confirmed.
  defp arm_confirmed(socket, fresh) do
    case Billing.set_auto_recharge_setting(fresh, %{mode: "auto"},
           actor: socket.assigns.current_user
         ) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> put_flash(:info, "Auto charging armed.")
         |> assign(auto_recharge_setting: setting, arm_confirm?: false)
         |> assign(auto_recharge_form: post_save_auto_recharge_form(setting))}

      {:error, _rejected_by_the_domain} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Couldn't arm auto charging. Check the charge settings and try again."
         )
         |> assign(arm_confirm?: false)}
    end
  end

  defp terms_match?(fresh, params) do
    snapshot_terms(params) == %{
      amount_cents: fresh.amount_cents,
      threshold_cents: fresh.threshold_cents,
      daily_charge_cap: fresh.daily_charge_cap,
      failure_strikes: fresh.failure_strikes
    }
  end

  defp snapshot_terms(params) do
    %{
      amount_cents: snapshot_int(params["amount"]),
      threshold_cents: snapshot_int(params["threshold"]),
      daily_charge_cap: snapshot_int(params["cap"]),
      failure_strikes: snapshot_int(params["strikes"])
    }
  end

  defp snapshot_int(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    case Integer.parse(trimmed) do
      {value, ""} -> value
      _malformed -> nil
    end
  end

  defp snapshot_int(_missing_or_malformed), do: nil

  # The card's prefilled form: whole dollars, the wizard Amount step's
  # unit. Members get no form (nil) — the card renders the read-only
  # state alone. Gate-off the form is L3's launch shape exactly (the
  # parity pin); gate-on it carries the charge dials and the buyer
  # evidence (S5).
  defp prefilled_auto_recharge_form(_setting, false = _owner?, _org, _user, _charge_mode?),
    do: nil

  defp prefilled_auto_recharge_form(setting, true = _owner?, _org, _user, false = _gate_on?),
    do: launch_auto_recharge_form(setting)

  defp prefilled_auto_recharge_form(setting, true = _owner?, org, user, true = _gate_on?),
    do: charge_auto_recharge_form(setting, evidence_defaults(org, user))

  # L3's launch map — gate-off the card must read byte-for-byte as it
  # shipped (the parity pin).
  defp launch_auto_recharge_form(setting) do
    to_form(
      %{
        "mode" => Atom.to_string(setting.mode),
        "threshold_dollars" => prefilled_dollars(setting.threshold_cents),
        "amount_dollars" => prefilled_dollars(setting.amount_cents)
      },
      as: :auto_recharge
    )
  end

  # After a successful save the form re-prefills from the persisted
  # row: gate-off that's L3's shape; gate-on the charge fields with the
  # SETTING'S evidence (the top-up lookup rode the mount, and the save
  # just wrote the row).
  defp post_save_auto_recharge_form(setting) do
    if Billing.auto_recharge_charge_mode?() do
      charge_auto_recharge_form(setting, %{})
    else
      launch_auto_recharge_form(setting)
    end
  end

  # The gate-on form (S5): L3's fields plus the charge dials and buyer
  # evidence. The dials prefill from the stored row; the evidence
  # prefills from the row, falling back to the org's LAST COMPLETED
  # top-up where the row is empty (decision C's copy-as-default —
  # editable defaults, never overwriting stored values). customer_type
  # is never empty on the row (default :consumer), so it always reads
  # the row.
  defp charge_auto_recharge_form(setting, evidence_defaults) do
    to_form(
      %{
        "mode" => Atom.to_string(setting.mode),
        "threshold_dollars" => prefilled_dollars(setting.threshold_cents),
        "amount_dollars" => prefilled_dollars(setting.amount_cents),
        "daily_charge_cap" => Integer.to_string(setting.daily_charge_cap),
        "failure_strikes" => Integer.to_string(setting.failure_strikes),
        "billing_country" =>
          evidence_prefill(setting.billing_country, evidence_defaults["billing_country"]),
        "billing_state" =>
          evidence_prefill(setting.billing_state, evidence_defaults["billing_state"]),
        "vat_number" => evidence_prefill(setting.vat_number, evidence_defaults["vat_number"]),
        "customer_type" => Atom.to_string(setting.customer_type)
      },
      as: :auto_recharge
    )
  end

  defp evidence_prefill(setting_value, fallback), do: setting_value || fallback || ""

  # Decision C's copy-as-default: the org's LAST COMPLETED top-up's
  # buyer evidence is the editable default for the empty setting
  # fields — a member-visible read (the org's own money history). The
  # RATE is never copied (#260).
  defp evidence_defaults(org, user) do
    case latest_completed_topup(org, user) do
      nil ->
        %{}

      topup ->
        %{
          "billing_country" => topup.billing_country,
          "billing_state" => topup.billing_state,
          "vat_number" => topup.vat_number
        }
    end
  end

  defp latest_completed_topup(org, user) do
    Topup
    |> Ash.Query.filter(organization_id == ^org.id and status == :completed)
    |> Ash.Query.sort(created_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: user)
    |> Enum.at(0)
  end

  # The card's recent auto activity (#829 S5): the last 3 `:auto` rows,
  # member-visible like the ledger. :manual rows (the wizard's) never
  # enter this list.
  defp recent_auto_topups(org, user) do
    Topup
    |> Ash.Query.filter(organization_id == ^org.id and origin == :auto)
    |> Ash.Query.sort(created_at: :desc, id: :desc)
    |> Ash.Query.limit(3)
    |> Ash.read!(actor: user)
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
  # L1) — with one deliberate carve-out: a mode-off save is MODE-ONLY.
  # The never-floor rule leaves the dollar inputs empty on a non-round
  # row, and demanding a valid dollar figure just to switch reminders
  # off would force the owner to re-enter stored values they aren't
  # changing — the stored threshold/amount survive untouched. For a
  # reminder save the whole-dollar rules apply: threshold ≥ $1 (the
  # attribute constraint's floor in the form's whole-dollar unit),
  # amount ≥ the wizard's floor (Billing.min_topup_dollars/0 — the
  # same unit the one-click link pre-fills). Any other mode — absent,
  # or a crafted non-scalar — rides to the domain as typed: the enum
  # and the AutoArmGate are the authority (a crafted `:auto` is
  # refused by the domain, not by this card).
  defp auto_recharge_inputs(params) do
    case params["mode"] do
      "off" ->
        {:ok, %{mode: "off"}}

      mode when is_binary(mode) ->
        min_dollars = Billing.min_topup_dollars()

        with {:ok, threshold} <-
               whole_dollars(params["threshold_dollars"], 1, threshold_error()),
             {:ok, amount} <-
               whole_dollars(params["amount_dollars"], min_dollars, amount_error()),
             {:ok, charge} <- gate_on_charge_inputs(params) do
          {:ok,
           Map.merge(
             %{mode: mode, threshold_cents: threshold * 100, amount_cents: amount * 100},
             charge
           )}
        end

      crafted_mode ->
        {:ok, %{mode: crafted_mode}}
    end
  end

  # Gate-on the save carries the charge dials + evidence (S5); gate-off
  # it stays L3's shape — a crafted gate-off payload must not write
  # charge fields (the launch posture makes the form never send them).
  defp gate_on_charge_inputs(params) do
    if Billing.auto_recharge_charge_mode?() do
      charge_inputs(params)
    else
      {:ok, %{}}
    end
  end

  # Server-side mirrors of the resource's constraints (#829 S2) — the
  # domain stays the authority, the form is UX. Evidence strings ride
  # trimmed, nil clears (the add-method enabler reads the stored row);
  # customer_type rides as typed — the enum refuses crafted values at
  # the domain.
  defp charge_inputs(params) do
    with {:ok, cap} <- bounded_int(params["daily_charge_cap"], 1, 6, cap_error()),
         {:ok, strikes} <- bounded_int(params["failure_strikes"], 2, 5, strikes_error()) do
      {:ok,
       %{
         daily_charge_cap: cap,
         failure_strikes: strikes,
         billing_country: present_string(params["billing_country"]),
         billing_state: present_string(params["billing_state"]),
         vat_number: present_string(params["vat_number"]),
         customer_type: params["customer_type"]
       }}
    end
  end

  defp bounded_int(raw, min, max, message) when is_binary(raw) do
    trimmed = String.trim(raw)

    case Integer.parse(trimmed) do
      {value, ""} when value >= min and value <= max -> {:ok, value}
      _out_of_bounds_or_malformed -> {:error, message}
    end
  end

  defp bounded_int(_missing_or_malformed, _min, _max, message), do: {:error, message}

  defp present_string(raw) when is_binary(raw) do
    trimmed = String.trim(raw)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present_string(_missing_or_malformed), do: nil

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
    |> assign(auto_recharge_form: auto_recharge_form(params))
  end

  # A crafted payload's non-scalar values (nested maps/lists) would
  # raise Phoenix.HTML.Safe at render — options_for_select and number
  # inputs take strings. The form carries binary values only; anything
  # else is dropped (the server-side validation judges the RAW params,
  # so the domain seam still answers crafted data).
  defp auto_recharge_form(params) do
    params
    |> Enum.filter(fn {_key, value} -> is_binary(value) end)
    |> Map.new()
    |> to_form(as: :auto_recharge)
  end

  defp default_auto_recharge_error,
    do: "Couldn't save the reminder settings. Check the values and try again."

  defp threshold_error, do: "The threshold must be a whole-dollar amount of at least $1."

  defp amount_error do
    "The amount must be a whole-dollar amount of at least $#{Billing.min_topup_dollars()}."
  end

  defp cap_error, do: "Max charges per day must be between 1 and 6."

  defp strikes_error, do: "The decline limit must be between 2 and 5."

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
              charge_mode?={@charge_mode?}
              arm_confirm?={@arm_confirm?}
              auto_topups={@auto_topups}
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
