defmodule FluxVale.Billing.Operations.SweepAutoRecharge do
  @moduledoc """
  The auto-recharge sweep (#829): one hourly pass (Workers.RechargeSweep)
  over the fleet's armed orgs, in per-org isolation — one bad org (or
  one poison stale row) is logged and skipped so the rest still gets
  served, and the pass reports failure so the job fails after the loop
  and Oban retries the hour (the zero-balance ladder's stance).

  Three arms, in order:

  - **Stale-pending reconciliation** (S4, decision E — runs FIRST, gate-on
    only): every `:pending` `origin: :auto` top-up older than one hour
    gets its answer before any due-check. No persisted order id → the
    draft leg never completed, nothing can charge → `mark_failed`.
    Order id present → `fetch_order` through `ReconcileTopup`'s order
    lane: paid → the same idempotent credit the webhook posts;
    still-draft → `mark_failed` (an unfinalized draft can never charge);
    a gateway fault leaves the row pending for the next pass — failing a
    possibly-charged row would block its credit (CompleteTopup refuses
    failed rows). Local expiry (#364) remains the backstop at 24h.
  - **The reminder arm** (L2, the launch lane): per org armed in
    `:reminder` mode, read the balance (no lock — the reminder writes no
    wallet state) and, below threshold, email the members a one-click,
    amount-prefilled top-up link; marker and mail commit together.
    Behavior is unchanged since L2.
  - **The charge arm** (S4, STAGED — the whole arm, stale reconciliation
    included, is skipped gate-off): per org in `:auto` mode. The
    load-bearing boundary: **the locked transaction DECIDES, the charge
    runs OUTSIDE it.** The method lookup (`list_payment_methods`) runs
    BEFORE the lock (a stalled provider call must never hold the
    wallet); then ONE transaction takes `WalletLock`, re-reads the
    balance fresh, evaluates due (below threshold AND no in-flight
    `:pending` auto attempt AND auto charges in the last 24h under
    `daily_charge_cap`) and commits that DECISION — the charge
    (`Billing.start_auto_recharge`, whose own row insert is durable
    before any network) happens only after it returns. S3's operation
    owns the strike writes; the sweep only re-reads the counter for the
    disable decision. At `failure_strikes` → `disable_with_reason(
    :declines)` + the disable mail (decision F). No method → D3's
    two-pass rule, outside the lock: first pass notices (mail + marker
    atomic), second pass disables (`:no_method`). A success clears the
    notice marker; unknown/draft/attach outcomes leave the row to the
    stale arm and never count a strike.
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.AutoRechargeSetting
  alias FluxVale.Billing.Topup
  alias FluxVale.Billing.Wallet
  alias FluxVale.Billing.WalletLock
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Mailer

  require Ash.Query
  require Logger

  # The reminder cadence is fixed, not a dial (decision D2): at most one
  # reminder per 24h per episode. Revisit on the first complaint about
  # mailbox fatigue — not before.
  @reminder_cadence_hours 24

  # Stale = pending longer than one hour (decision E): an hourly sweep
  # answers every unresolved attempt within two passes.
  @stale_pending_hours 1

  # The rolling charge window (decision D2): daily_charge_cap counts
  # completed-or-failed auto charges inside it. The cap counts CHARGES,
  # not cents.
  @charge_window_hours 24

  @spec call() ::
          {:ok,
           %{
             reminded: non_neg_integer(),
             recovered: non_neg_integer(),
             charged: non_neg_integer()
           }}
          | {:error, String.t()}
  def call do
    # The stale reconciliation runs FIRST (decision E) so a failed stale
    # row frees the in-flight guard within the same pass.
    stale_outcomes = stale_pending_outcomes()

    reminder_outcomes = Enum.map(reminder_settings(), &safe_sweep(&1, :reminder))
    outcomes = stale_outcomes ++ reminder_outcomes ++ charge_arm_outcomes()

    {passes, failures} = Enum.split_with(outcomes, &pass?/1)

    kinds = Enum.map(passes, fn {:ok, kind} -> kind end)
    counts = Enum.frequencies(kinds)

    case failures do
      [] ->
        {:ok,
         %{
           reminded: Map.get(counts, :reminded, 0),
           recovered: Map.get(counts, :recovered, 0),
           charged: Map.get(counts, :charged, 0)
         }}

      _failed ->
        {:error, "auto-recharge sweep failed for #{length(failures)} org(s)"}
    end
  end

  # ── The arms ──

  # Gate-on only: with the platform gate off, no org is charged, no
  # provider is called, and no stale row is resolved — the launch lane
  # is the reminder arm alone.
  defp stale_pending_outcomes do
    if Billing.auto_recharge_charge_mode?() do
      stale_cutoff = DateTime.add(DateTime.utc_now(), -@stale_pending_hours, :hour)

      # System read: the sweep reconciles the fleet's stale auto rows.
      Topup
      |> Ash.Query.filter(origin == :auto and status == :pending and created_at < ^stale_cutoff)
      |> Ash.read!(authorize?: false)
      |> Enum.map(&safe_stale/1)
    else
      []
    end
  end

  defp reminder_settings do
    # System read: the sweep walks every org armed for reminders.
    AutoRechargeSetting
    |> Ash.Query.filter(mode == :reminder)
    |> Ash.read!(authorize?: false)
  end

  defp charge_arm_outcomes do
    if Billing.auto_recharge_charge_mode?() do
      # System read: the sweep walks every org armed for auto charges.
      AutoRechargeSetting
      |> Ash.Query.filter(mode == :auto)
      |> Ash.read!(authorize?: false)
      |> Enum.map(&safe_sweep(&1, :charge))
    else
      []
    end
  end

  # ── Per-org isolation (both arms) ──

  defp pass?({:ok, _kind}), do: true
  defp pass?({:error, _reason}), do: false

  # A crash in one org's pass must not eat the rest of the fleet: the
  # org is logged and skipped, the failure rides back to the caller (the
  # job fails after the loop, so Oban retries the hour).
  defp safe_sweep(setting, arm) do
    case sweep(setting, arm) do
      {:ok, kind} ->
        {:ok, kind}

      {:error, reason} ->
        log_failure(setting, arm, reason)
        {:error, reason}
    end
  rescue
    exception ->
      log_failure(setting, arm, exception)
      {:error, exception}
  end

  defp sweep(setting, :reminder), do: pass(setting)
  defp sweep(setting, :charge), do: charge_pass(setting)

  defp log_failure(setting, arm, reason) do
    Logger.error(
      "Auto-recharge #{arm} sweep failed for org #{setting.organization_id}: #{inspect(reason)}"
    )
  end

  # ── The reminder arm (L2, unchanged) ──

  # The balance read carries NO advisory lock and NO transaction around
  # it: the reminder writes no wallet state, so there is nothing to
  # serialize — a balance that moves mid-read only shifts the reminder
  # by one pass. The marker and the mail, by contrast, commit together
  # (remind/1), so the read and the write deliberately sit apart.
  defp pass(setting) do
    # System reads: the sweep is actorless (the ladder's stance).
    wallet = Wallet.get_by_organization!(setting.organization_id, authorize?: false)
    loaded = Ash.load!(wallet, :balance, authorize?: false)
    balance_cents = loaded.balance || 0

    outcome =
      FluxVale.Repo.transaction(fn ->
        cond do
          due?(setting, balance_cents) ->
            remind(setting)

          recovered?(setting, balance_cents) ->
            clear_marker(setting)

          true ->
            :idle
        end
      end)

    case outcome do
      {:ok, kind} ->
        {:ok, kind}

      # A rolled-back pass (a failed send) is this org's isolated
      # failure — the marker never landed, the next hourly pass retries.
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Due: below the threshold AND never reminded, or the last reminder
  # is older than the cadence (the episode re-arms).
  defp due?(setting, balance_cents) do
    low?(setting, balance_cents) and reminder_due?(setting.last_reminded_at)
  end

  defp low?(setting, balance_cents), do: balance_cents < setting.threshold_cents

  defp reminder_due?(nil), do: true

  defp reminder_due?(last_reminded_at) do
    now = DateTime.utc_now()

    DateTime.compare(now, DateTime.add(last_reminded_at, @reminder_cadence_hours, :hour)) != :lt
  end

  # Recovery clears the marker (episode re-arm — the ladder-warning
  # shape): the next dip starts a fresh episode, not a silent one.
  defp recovered?(setting, balance_cents) do
    not low?(setting, balance_cents) and not is_nil(setting.last_reminded_at)
  end

  # The reminder arm: mail first, marker second, one transaction (the
  # caller's) — a failed send rolls the whole pass back.
  defp remind(setting) do
    # System seam — the sweep is actorless; membership is policy-guarded
    # for actors, not for the lifecycle machinery.
    org = Ash.get!(Organization, setting.organization_id, authorize?: false)

    deliver_to_members(org, fn email ->
      Mailer.deliver_auto_recharge_reminder(
        email,
        setting.threshold_cents,
        setting.amount_cents,
        topup_url(org, setting)
      )
    end)

    {:ok, _reminded} = write_marker(setting, DateTime.utc_now())
    :reminded
  end

  # The marker write, via the resource's system action (the wallet's
  # set_ladder_state shape: actor-forbidden by policy; the sweep owns
  # every write).
  defp write_marker(setting, at) do
    setting
    |> Ash.Changeset.for_update(:record_reminder, %{last_reminded_at: at}, authorize?: false)
    |> Ash.update()
  end

  defp clear_marker(setting) do
    {:ok, _cleared} = write_marker(setting, nil)
    :recovered
  end

  # ── The charge arm (S4, staged) ──

  # The METHOD LOOKUP runs BEFORE the lock (a stalled provider call
  # must never hold the wallet — the plan pins it); a method removed
  # between lookup and charge is answered by finalize's 402 and counts
  # as a failure like any decline.
  defp charge_pass(setting) do
    # System seam — the sweep is actorless.
    org = Ash.get!(Organization, setting.organization_id, authorize?: false)

    case method_lookup(setting) do
      {:ok, count, _default_ref} when count > 0 ->
        due_then_charge(org, setting)

      {:ok, _none, _no_ref} ->
        no_method_pass(org, setting)

      {:error, reason} ->
        {:error, {:method_lookup, reason}}
    end
  end

  defp method_lookup(%AutoRechargeSetting{provider_customer_id: nil}) do
    # Drift (an armed row with no stored customer) reads as "no method
    # known" and rides D3 like an empty provider answer — the sweep
    # must not crash on it.
    {:ok, 0, nil}
  end

  defp method_lookup(setting) do
    provider = Application.fetch_env!(:flux_vale, :payments_provider)
    provider.list_payment_methods(setting.provider_customer_id)
  end

  # The boundary: ONE transaction — lock, fresh re-read, decision — and
  # NOTHING else. The charge (its own row insert, then its own network
  # legs) runs only after this commits; a network call never holds the
  # lock (the suspend_gateways discipline).
  defp due_then_charge(org, setting) do
    outcome =
      FluxVale.Repo.transaction(fn ->
        # System reads: the sweep is actorless.
        wallet = Wallet.get_by_organization!(org.id, authorize?: false)
        WalletLock.acquire(wallet)

        loaded = Ash.load!(wallet, :balance, authorize?: false)

        charge_due?(org.id, setting, loaded.balance || 0)
      end)

    case outcome do
      {:ok, true} ->
        record_charge_outcome(org, setting, Billing.start_auto_recharge(org, setting))

      {:ok, false} ->
        {:ok, :idle}
    end
  end

  # Due (decisions D/E): below the threshold AND no in-flight auto
  # attempt (at most one — the fixed invariant) AND the rolling-24h
  # charge count under the cap. The row-fact reads sit INSIDE the lock,
  # serialized with the balance read. The decision transaction has no
  # rollback source — a DB fault raises into safe_sweep (the org's
  # isolated failure).
  defp charge_due?(organization_id, setting, balance_cents) do
    low?(setting, balance_cents) and
      not pending_auto_topup?(organization_id) and
      auto_charges_last_24h(organization_id) < setting.daily_charge_cap
  end

  defp pending_auto_topup?(organization_id) do
    # System read (the in-flight invariant, decision D).
    found =
      Topup
      |> Ash.Query.filter(
        organization_id == ^organization_id and origin == :auto and status == :pending
      )
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)

    found != []
  end

  defp auto_charges_last_24h(organization_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -@charge_window_hours, :hour)

    # System read (the cap counts CHARGES, not cents — decision D).
    Topup
    |> Ash.Query.filter(
      organization_id == ^organization_id and origin == :auto and
        status in [:completed, :failed] and created_at > ^cutoff
    )
    |> Ash.count!(authorize?: false)
  end

  # The outcome mapping: S3's operation already wrote the row state and
  # the strike counter — the sweep never double-writes those. It owns
  # the marker clear on success and the disable decision on a counted
  # decline (re-read: the in-memory row predates S3's increment).
  defp record_charge_outcome(org, setting, outcome) do
    case outcome do
      {:ok, :completed, _topup} ->
        clear_no_method_marker(setting)
        {:ok, :charged}

      {:ok, :failed, _topup, _reason} ->
        decline_followup(org, reloaded_setting(setting))

      # A racer settled the row mid-flight — S3 counted nothing, so
      # there is no strike to follow up.
      {:ok, :already_terminal, _topup} ->
        {:ok, :settled}

      # Unknown outcome: the row stays pending (with its order id) for
      # the stale arm; unknowns never count a strike.
      {:error, :unknown, _topup} ->
        {:ok, :unknown}

      # The row stays pending WITHOUT an order id — the stale arm fails
      # it (an unfinalizable draft); no strike.
      {:error, :draft_failed, _topup} ->
        {:ok, :unfinalized}

      {:error, :attach_failed, _topup} ->
        {:ok, :unfinalized}

      # A config/consent race (the gate flipped mid-pass, an owner
      # disarmed mid-pass): skip — the next pass re-evaluates.
      {:error, reason}
      when reason in [:charge_mode_off, :setting_not_armed, :setting_org_mismatch] ->
        Logger.warning(
          "Auto-recharge charge skipped for org #{org.id} (config/consent race): #{inspect(reason)}"
        )

        {:ok, :skipped}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reloaded_setting(setting) do
    AutoRechargeSetting.get_by_organization!(setting.organization_id, authorize?: false)
  end

  # Decision F: at `failure_strikes` consecutive ANSWERED failures the
  # lane disables — the mail (with the one-click top-up link) and the
  # disable commit together, so a failed send rolls the disable back
  # and the next pass re-decides (the marker+mail discipline).
  defp decline_followup(org, fresh) do
    if fresh.consecutive_failures >= fresh.failure_strikes do
      outcome =
        FluxVale.Repo.transaction(fn ->
          deliver_disable_mail(org, fresh)
          disable_setting(fresh, :declines)
          :disabled
        end)

      case outcome do
        {:ok, kind} -> {:ok, kind}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, :declined}
    end
  end

  # A success clears the notice marker (decision D3/F — the two-pass
  # cycle re-arms fresh); a no-op when it was never set.
  defp clear_no_method_marker(setting) do
    unless is_nil(setting.no_method_notified_at) do
      {:ok, _cleared} = notice_marker(setting, nil)
    end

    :ok
  end

  # D3's two-pass rule, OUTSIDE the lock (no wallet state is written):
  # pass one notices (mail + marker in ONE transaction — a failed send
  # rolls the marker back), pass two disables (mail + disable in ONE
  # transaction — same discipline).
  defp no_method_pass(org, setting) do
    outcome =
      if is_nil(setting.no_method_notified_at) do
        FluxVale.Repo.transaction(fn ->
          deliver_no_method_mail(org)
          {:ok, _marked} = notice_marker(setting, DateTime.utc_now())
          :notified
        end)
      else
        FluxVale.Repo.transaction(fn ->
          deliver_no_method_mail(org)
          disable_setting(setting, :no_method)
          :disabled
        end)
      end

    case outcome do
      {:ok, kind} -> {:ok, kind}
      {:error, reason} -> {:error, reason}
    end
  end

  defp notice_marker(setting, at) do
    setting
    |> Ash.Changeset.for_update(:record_no_method_notice, %{no_method_notified_at: at},
      authorize?: false
    )
    |> Ash.update()
  end

  # The disable write (decision D3/F): mode :off, the reason recorded,
  # the strikes reset, the notice marker cleared (the action's own
  # semantics).
  defp disable_setting(setting, reason) do
    setting
    |> Ash.Changeset.for_update(:disable_with_reason, %{disabled_reason: reason},
      authorize?: false
    )
    |> Ash.update()
  end

  defp deliver_no_method_mail(org) do
    deliver_to_members(org, &Mailer.deliver_auto_recharge_no_method/1)
  end

  defp deliver_disable_mail(org, setting) do
    deliver_to_members(org, fn email ->
      Mailer.deliver_auto_recharge_disabled(email, topup_url(org, setting))
    end)
  end

  # The one-click link (#829 L2): the ORG route carrying the saved
  # amount in whole dollars — the wizard prefills its Amount step from
  # the `amount` param. A member whose personal org IS this org rides
  # the wizard's redirect, which carries the query through to the
  # personal route.
  defp topup_url(org, setting) do
    amount_dollars = div(setting.amount_cents, 100)

    Mailer.canonical_url("/organizations/#{org.slug}/billing/topup?amount=#{amount_dollars}")
  end

  # ── Delivery (member emails; mail and its marker commit together) ──

  defp deliver_to_members(org, mail) do
    case member_emails(org) do
      # Nothing to deliver — the caller's marker still sets (remind/1,
      # no_method_pass): the episode must not re-fire every hour for an
      # org nobody can reach.
      [] ->
        :ok

      addresses ->
        Enum.each(addresses, fn address -> deliver_one(mail, address) end)
    end
  end

  defp deliver_one(mail, email) do
    case mail.(email) do
      {:ok, _delivery} ->
        :ok

      # A failed send rolls the caller's transaction back — the marker
      # (or the disable) cannot outlive its mail (the ladder's
      # discipline). Unlike the ladder's adapter-internal failure, this
      # seam is stubbable, so the rollback branch is test-proven here.
      {:error, reason} ->
        FluxVale.Repo.rollback(reason)
    end
  end

  # ── The stale-pending reconciliation ──

  # Per-row isolation (the org arms' safe_sweep shape): one poison row
  # is logged and skipped, its failure rides into the pass verdict —
  # the job fails after the loop, so Oban retries the hour.
  defp safe_stale(row) do
    {:ok, reconcile_stale(row)}
  rescue
    exception ->
      Logger.error("Auto-recharge stale top-up #{row.id} failed: #{inspect(exception)}")
      {:error, exception}
  end

  defp reconcile_stale(%Topup{payment_request_id: nil} = row) do
    # The draft leg never completed — the order id persists BEFORE any
    # finalize (decision E), so with no id nothing can have charged.
    fail_pending_row(row)
  end

  defp reconcile_stale(%Topup{payment_request_id: id} = row) do
    case Billing.reconcile_topup(id, :order) do
      {:ok, %Topup{}} ->
        :credited

      {:ok, :already_completed} ->
        :settled

      # A still-draft order was never finalized — nothing can have
      # charged; fail it.
      {:ok, :unfinalized} ->
        fail_pending_row(row)

      # A paid order without a usable amount, or an unknown status —
      # the order.paid webhook owns the outcome.
      {:ok, :pending} ->
        :left

      # Gateway fault (transport, api, a 404): leave the row pending —
      # failing a possibly-charged row on an untrusted answer would
      # block its credit; the next pass retries.
      {:error, reason} ->
        log_stale_left(row, reason)
    end
  end

  # Terminal-once (the status-filtered bulk form S3 established): the
  # status filter rides the UPDATE's WHERE — a racer that settled the
  # row mid-flight loses instead of being flipped.
  defp fail_pending_row(row) do
    query = Ash.Query.filter(Topup, id == ^row.id and status == :pending)

    case Ash.bulk_update(query, :mark_failed, %{},
           authorize?: false,
           return_records?: true,
           notify?: false
         ) do
      %Ash.BulkResult{status: :success, records: [_failed]} -> :failed
      %Ash.BulkResult{status: :success, records: []} -> :settled
      %Ash.BulkResult{status: :error, errors: errors} -> log_stale_left(row, errors)
    end
  end

  defp log_stale_left(row, reason) do
    Logger.warning("Auto-recharge stale top-up #{row.id} left pending: #{inspect(reason)}")
  end

  # ── Member address resolution ──

  # The member→address resolution is DUPLICATED from SweepZeroBalance
  # on purpose: each operation owns its private helpers outright (the
  # operation-boundary rule) — follow the pattern, not the function.
  defp member_emails(org) do
    # System seam — the sweep is actorless; membership is policy-guarded
    # for actors, not for the lifecycle machinery.
    loaded = Ash.load!(org, :members, authorize?: false)

    # The recipient is the member's primary VERIFIED address (#285 T3,
    # #287 — user_emails is the only address storage). A member without
    # one (data drift — actions always stamp the primary) has nowhere
    # to send and is skipped.
    Enum.flat_map(loaded.members, fn member ->
      case primary_address(member.id) do
        {:ok, address} -> [address]
        :none -> []
      end
    end)
  end

  defp primary_address(user_id) do
    found =
      UserEmail
      |> Ash.Query.filter(user_id == ^user_id and is_primary and not is_nil(verified_at))
      |> Ash.read_one!(authorize?: false)

    case found do
      %{address: address} -> {:ok, to_string(address)}
      nil -> :none
    end
  end
end
