defmodule FluxVale.Billing.Operations.SweepAutoRecharge do
  @moduledoc """
  The auto-recharge reminder sweep (#829 L2): for every org armed in
  `:reminder` mode, an hourly pass (Workers.RechargeSweep) reads the
  wallet balance and, while it sits below the org's threshold, emails
  the org's members a one-click, amount-prefilled top-up link. The
  reminder lane writes NO wallet state and charges nothing — the top-up
  it produces is an ordinary manual one through the wizard (decision A);
  the off-session charge arm stages in later (S4).

  Per-org isolation: one bad org is logged and skipped so the rest of
  the fleet still hears, and the pass reports failure so the job fails
  after the loop and Oban retries the hour (the zero-balance ladder's
  stance).

  The marker and the mail commit together — a failed send rolls the
  marker write back, so a marker can never outlive its mail and the
  next hourly pass retries the org (the ladder-warning discipline).
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing.AutoRechargeSetting
  alias FluxVale.Billing.Wallet
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Mailer

  require Ash.Query
  require Logger

  # The cadence is fixed, not a dial (decision D2): at most one
  # reminder per 24h per episode. Revisit on the first complaint about
  # mailbox fatigue — not before.
  @reminder_cadence_hours 24

  @spec call() ::
          {:ok, %{reminded: non_neg_integer(), recovered: non_neg_integer()}}
          | {:error, String.t()}
  def call do
    # System read: the sweep walks every org armed for reminders.
    settings =
      AutoRechargeSetting
      |> Ash.Query.filter(mode == :reminder)
      |> Ash.read!(authorize?: false)

    outcomes = Enum.map(settings, &safe_sweep/1)
    {passes, failures} = Enum.split_with(outcomes, &pass?/1)

    kinds = Enum.map(passes, fn {:ok, kind} -> kind end)
    counts = Enum.frequencies(kinds)

    case failures do
      [] ->
        {:ok,
         %{reminded: Map.get(counts, :reminded, 0), recovered: Map.get(counts, :recovered, 0)}}

      _failed ->
        {:error, "auto-recharge reminder sweep failed for #{length(failures)} org(s)"}
    end
  end

  defp pass?({:ok, _kind}), do: true
  defp pass?({:error, _reason}), do: false

  # A crash in one org's pass must not eat the rest of the fleet: the
  # org is logged and skipped, the failure rides back to the caller (the
  # job fails after the loop, so Oban retries the hour).
  defp safe_sweep(setting) do
    case pass(setting) do
      {:ok, kind} ->
        {:ok, kind}

      {:error, reason} ->
        log_failure(setting, reason)
        {:error, reason}
    end
  rescue
    exception ->
      log_failure(setting, exception)
      {:error, exception}
  end

  defp log_failure(setting, reason) do
    Logger.error(
      "Auto-recharge reminder sweep failed for org #{setting.organization_id}: #{inspect(reason)}"
    )
  end

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

    deliver_to_members(org, setting)

    {:ok, _reminded} = write_marker(setting, DateTime.utc_now())
    :reminded
  end

  defp deliver_to_members(org, setting) do
    case member_emails(org) do
      # Nothing to deliver — but the marker still sets (remind/1): the
      # episode must not re-fire every hour for an org nobody can
      # reach. The next due pass is a day out, like any other reminder.
      [] ->
        :ok

      addresses ->
        Enum.each(addresses, &deliver_reminder(org, setting, &1))
    end
  end

  defp deliver_reminder(org, setting, email) do
    threshold_cents = setting.threshold_cents
    amount_cents = setting.amount_cents

    case Mailer.deliver_auto_recharge_reminder(
           email,
           threshold_cents,
           amount_cents,
           topup_url(org, setting)
         ) do
      {:ok, _delivery} ->
        :ok

      # A failed send rolls the whole pass back — the marker cannot
      # outlive its mail (the ladder's discipline). Unlike the ladder's
      # adapter-internal failure, this seam is stubbable, so the
      # rollback branch is test-proven here.
      {:error, reason} ->
        FluxVale.Repo.rollback(reason)
    end
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
