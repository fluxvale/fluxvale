defmodule FluxVale.Billing.Operations.SweepZeroBalance do
  @moduledoc """
  Walks the zero-balance ladder for one wallet (#124): runway warning →
  auto-stop → destroy window. One Oban worker calls this per wallet,
  hourly; every state transition and marker write happens under the
  wallet's advisory lock (the DebitWallet discipline — a top-up racing
  the sweep serializes, so a stop never lands on a wallet that just
  refilled).

  The ladder, decided on #124:

  - runway < 24h of burn → one warning email per episode
    (`low_balance_warned_at`, cleared when runway recovers)
  - balance ≤ 0 → every `:running` instance stops (the pause pitch —
    reversible: `start`'s gate reopens the moment balance > 0), and
    every `:active` access gateway **suspends** (ADR-0039 §5's must-fix:
    an unfunded gateway is a paid-for reachability the org is not
    paying for — scaled to zero, no accrual, reversible on top-up)
  - balance < 0 → the destroy clock anchors at `negative_since`;
    destroy all the org's instances at +30d (teardown machinery,
    storage freed — the data-deletion statement's commitment), T-7/T-1
    warnings once each; a recovery to ≥ 0 clears clock and markers.
    The anchor survives the destroy: an org that stays negative keeps
    its past-due clock (every later sweep re-enters the destroy arm,
    a no-op that sends nothing) instead of re-arming 30-day warning
    cycles for an abandoned wallet.

  Emails ride the Swoosh/TestInbox path from inside the transaction: a
  marker set without its mail (or the reverse) can't happen — a failed
  send rolls the whole pass back and the next sweep retries.
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing.Operations.ComputeRunway
  alias FluxVale.Billing.Wallet
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Mailer

  require Ash.Query

  @destroy_after_days 30
  @warning_hours 24

  @enforce_keys [
    :runway_warning_sent,
    :destroy_warning,
    :stopped_ids,
    :destroyed_ids,
    :suspended_gateway_ids
  ]
  defstruct [
    :runway_warning_sent,
    :destroy_warning,
    :stopped_ids,
    :destroyed_ids,
    :suspended_gateway_ids
  ]

  @type t :: %__MODULE__{
          runway_warning_sent: boolean(),
          destroy_warning: nil | :t7 | :t1,
          stopped_ids: [Ash.UUID.t()],
          destroyed_ids: [Ash.UUID.t()],
          suspended_gateway_ids: [Ash.UUID.t()]
        }

  @spec call(Wallet.t()) :: {:ok, t()} | {:error, term()}
  def call(%Wallet{} = wallet) do
    outcome =
      FluxVale.Repo.transaction(fn ->
        # Lock FIRST, then re-read (the settle discipline): the lock
        # serializes this wallet against posters and top-ups; the re-read
        # sees the winner's committed state.
        FluxVale.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [wallet.id])

        with {:ok, fresh} <- Ash.get(Wallet, wallet.id, authorize?: false),
             {:ok, loaded} <- Ash.load(fresh, :balance, authorize?: false),
             {:ok, runway} <- ComputeRunway.call(loaded),
             {:ok, summary, markers} <- ladder(loaded, runway) do
          {:ok, _wallet} = write_markers(loaded, markers)
          summary
        else
          # defensive: the reads above only fail on a DB failure — not
          # simulatable under the sandbox
          # coveralls-ignore-start
          {:error, reason} ->
            FluxVale.Repo.rollback(reason)
            # coveralls-ignore-stop
        end
      end)

    case outcome do
      {:ok, summary} ->
        {:ok, summary}

      # defensive: rollback only fires from the arms that name it —
      # not simulatable under the sandbox
      # coveralls-ignore-start
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  defp ladder(wallet, runway) do
    now = DateTime.utc_now()

    # Mails decide before any K8s action runs: a failed send rolls the
    # whole pass back, and rollback can't un-scale a Deployment — so
    # the stop (the only out-of-DB side effect) goes last. Destroy's
    # teardown rides the transactional Oban insert and rolls back clean.
    {warning_markers, runway_sent?} = runway_step(wallet, runway)
    {destroy_markers, destroyed, destroy_warning} = destroy_step(wallet, now)
    stopped = stop_step(wallet)
    # Gateways go last for the same reason the stop does: it is the only
    # other out-of-DB side effect, and the mails must decide first.
    suspended = gateway_step(wallet)

    markers =
      warning_markers
      |> Map.merge(destroy_markers)
      |> anchor_negative_since(wallet, now)

    {:ok,
     %__MODULE__{
       runway_warning_sent: runway_sent?,
       destroy_warning: destroy_warning,
       stopped_ids: stopped,
       destroyed_ids: destroyed,
       suspended_gateway_ids: suspended
     }, markers}
  end

  # One warning email per low-runway episode; recovery (runway back
  # above 24h, or no burn at all) re-arms it. A balance already over
  # the cliff (negative runway) still warns — the email is the only
  # heads-up before the stop.
  defp runway_step(wallet, runway) do
    low? = runway.runway_hours != :infinity and runway.runway_hours < @warning_hours

    cond do
      low? and is_nil(wallet.low_balance_warned_at) ->
        deliver_to_members(wallet.organization_id, fn email ->
          Mailer.deliver_low_balance_warning(email, round(runway.runway_hours))
        end)

        {%{low_balance_warned_at: DateTime.utc_now()}, true}

      not low? and wallet.low_balance_warned_at ->
        {%{low_balance_warned_at: nil}, false}

      true ->
        {%{}, false}
    end
  end

  # The stop at ≤ 0 — data intact, storage-only accrual, reversible on
  # top-up (start's gate reopens at balance > 0). Non-running rows are
  # fed through and skip themselves: stop's own state guard is the
  # arbiter, so a reconciler flip mid-sweep is a skip, not a crash.
  #
  # The nested writes drop their PubSub notifications (Ash can't collect
  # them inside a manual transaction) — a sweep-stopped row shows its
  # status on the next page load; revisit only if the UI ever needs
  # live sweep updates.
  defp stop_step(wallet) do
    if wallet.balance <= 0 do
      stopped =
        for instance <- org_instances(wallet.organization_id),
            {:ok, stopped} <- [Instance.stop(instance, authorize?: false)] do
          stopped.id
        end

      stopped
    else
      []
    end
  end

  # The gateway arm (ADR-0039 §5): at ≤ 0 every `:active` gateway
  # suspends — scaled to zero, accrual parked, reversible on top-up. The
  # `suspend` action is its own guard (idempotent at `:suspended`), so a
  # re-entered ladder pass is a no-op, not a second K8s call.
  #
  # Suspension is deliberately NOT the destroy ladder: the gateway is
  # cheap to keep parked (no pod, kilobytes of state), and destroying it
  # would drop the owner's tailnet node identity — a re-join on every
  # top-up, which is a far worse experience than a pause.
  defp gateway_step(wallet) do
    if wallet.balance <= 0 do
      for gateway <- org_gateways(wallet.organization_id),
          {:ok, suspended} <- [AccessGateway.suspend(gateway, authorize?: false)] do
        suspended.id
      end
    else
      []
    end
  end

  defp org_gateways(organization_id) do
    AccessGateway
    |> Ash.Query.filter(organization_id == ^organization_id)
    |> Ash.read!(authorize?: false)
  end

  # The destroy clock: anchored when the sweep first sees balance < 0,
  # cleared at ≥ 0; warnings once each, most-urgent-first.
  defp destroy_step(wallet, now) do
    if wallet.balance < 0 do
      window_step(wallet, now)
    else
      if wallet.negative_since do
        # Recovery: clock and warning markers clear with it.
        {%{negative_since: nil, destroy_t7_warned_at: nil, destroy_t1_warned_at: nil}, [], nil}
      else
        {%{}, [], nil}
      end
    end
  end

  defp window_step(wallet, now) do
    since = wallet.negative_since || now
    destroy_at = DateTime.add(since, @destroy_after_days, :day)

    cond do
      DateTime.compare(now, destroy_at) != :lt ->
        # The anchor stays: see the moduledoc's abandoned-org note.
        {%{}, destroy_all(wallet.organization_id), nil}

      due?(now, destroy_at, 1) and is_nil(wallet.destroy_t1_warned_at) ->
        deliver_destroy_warning(wallet.organization_id, destroy_at, 1)

        # Both markers: a sweep that first reaches the window inside
        # T-1 (after an outage, say) must not send "in 7 days" on a
        # later pass — t1 supersedes t7.
        {%{destroy_t1_warned_at: now, destroy_t7_warned_at: wallet.destroy_t7_warned_at || now},
         [], :t1}

      due?(now, destroy_at, 7) and is_nil(wallet.destroy_t7_warned_at) ->
        deliver_destroy_warning(wallet.organization_id, destroy_at, 7)
        {%{destroy_t7_warned_at: now}, [], :t7}

      true ->
        {%{}, [], nil}
    end
  end

  # Is the T-minus warning `days` before destroy due yet?
  defp due?(now, destroy_at, days) do
    DateTime.compare(now, DateTime.add(destroy_at, -days, :day)) != :lt
  end

  defp destroy_all(organization_id) do
    # Gateways first: their teardown detaches every attached instance
    # (restoring each namespace to its private floor) before the
    # instances are torn down. Destroying instances first would leave a
    # gateway holding routes into namespaces that no longer exist.
    gateways = org_gateways(organization_id)
    Enum.each(gateways, &destroy_gateway/1)

    for instance <- org_instances(organization_id) do
      {:ok, _deleted} = Instance.delete(instance.id, authorize?: false)
      instance.id
    end
  end

  # The delete action flips :destroying and enqueues teardown; the
  # teardown trigger owns the cluster objects and the hard delete. An
  # already-destroying gateway is fed through (its own guard).
  defp destroy_gateway(%AccessGateway{} = gateway) do
    case AccessGateway.delete(gateway.id, authorize?: false) do
      {:ok, _deleting} ->
        :ok

      # coveralls-ignore-start - defensive: the action's get_by_id is
      # the only failure shape, and the row was just read
      {:error, _reason} ->
        :ok
        # coveralls-ignore-stop
    end
  end

  # The clock anchors at the FIRST negative sighting (destroy_step's
  # markers win when present — they already decided this pass).
  defp anchor_negative_since(markers, wallet, now) do
    cond do
      Map.has_key?(markers, :negative_since) ->
        markers

      wallet.balance < 0 and is_nil(wallet.negative_since) ->
        Map.put(markers, :negative_since, now)

      true ->
        markers
    end
  end

  defp write_markers(_wallet, markers) when map_size(markers) == 0 do
    {:ok, :unchanged}
  end

  defp write_markers(wallet, markers) do
    wallet
    |> Ash.Changeset.for_update(:set_ladder_state, markers, authorize?: false)
    |> Ash.update()
  end

  defp org_instances(organization_id) do
    Instance
    |> Ash.Query.for_read(:list_for_organization, %{organization_id: organization_id},
      authorize?: false
    )
    |> Ash.read!()
  end

  defp deliver_to_members(organization_id, deliver) do
    organization_id
    |> member_emails()
    |> Enum.each(fn email -> deliver_one(deliver, email) end)
  end

  defp deliver_one(deliver, email) do
    case deliver.(email) do
      {:ok, _delivery} ->
        :ok

      # A failed send rolls the whole pass back — the warning marker
      # cannot outlive its mail. Adapter failures aren't simulatable
      # under the sandbox (Swoosh Test/Local never fail).
      # coveralls-ignore-start
      {:error, reason} ->
        FluxVale.Repo.rollback(reason)
        # coveralls-ignore-stop
    end
  end

  defp deliver_destroy_warning(organization_id, destroy_at, days_left) do
    deliver_to_members(organization_id, fn email ->
      Mailer.deliver_destroy_warning(email, DateTime.to_date(destroy_at), days_left)
    end)
  end

  defp member_emails(organization_id) do
    # System seam — the sweep is actorless; membership is policy-guarded
    # for actors, not for the lifecycle machinery.
    organization =
      Organization
      |> Ash.get!(organization_id, authorize?: false)
      |> Ash.load!(:members, authorize?: false)

    Enum.map(organization.members, &to_string(&1.email))
  end
end
