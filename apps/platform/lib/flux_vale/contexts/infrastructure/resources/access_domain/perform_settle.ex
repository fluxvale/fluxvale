defmodule FluxVale.Infrastructure.AccessDomain.PerformSettle do
  @moduledoc """
  Custom-domain accrual (ADR-0040 §11): prorates the configured monthly
  rate over the open interval against the org wallet — the gateway
  settle's discipline verbatim (ADR-0039 §5), minus the transition
  instant (a domain row carries no `needs_attention_since`, so the
  honest end of an interval is the tick that closes it).

  The discipline, unchanged from the gateway:

  - **wallet advisory lock first**, so concurrent posters (this domain,
    the org's instances and its gateway settle on the same ticks)
    serialize and each reads the other's committed state;
  - **fresh `FOR UPDATE` re-read** of the domain, so the anchors that
    bill are the anchors that committed (a racing suspension parks
    them, and the settle must see the park);
  - **prorate in integer micro-cents** over the average Gregorian month
    (2_629_746 s — the same constant settle and the runway share);
  - **keyless debit** — the anchor is the retry arbiter, so a committed
    settle that advances `metering_since` can never recompute the same
    interval. No idempotency key, no new posting surface;
  - **anchor advance in the same transaction**, so a crash mid-settle
    re-bills nothing.

  Accrual arms: `:custom` rows in `:verified` OR `:needs_attention`.
  Both SERVE: `:verified` is the healthy posture, and `:needs_attention`
  is the cert's healing state whose issued wildcard is still valid —
  the routes and the claims stand (the TLS clause routes
  needs-attention rows), so the owner is getting the domain and it
  bills. `:pending`/`:failed` never accrued (unverified rows never
  routed — the edge skips them at mint), and `:suspended` accrues
  nothing by definition: the ladder's honest-dark arm, which parks the
  anchor on its way down. `:platform` rows never bill — the
  fluxvale.app hostname is free (§11).

  A **nil** `metering_since` arms the cursor without posting: the first
  tick after registration (or after a resume) opens the window, it does
  not bill from the epoch — the gateway's cold-start stance.

  The rate is NOT stored on the row (the gateway's `monthly_cents`
  snapshot has no domain cousin): one function reads the configured
  price (`AccessDomain.monthly_cents/0`), so a pricing change lands
  every accrual at the next tick without a migration.

  Attribution rides `subject: "access-domain:<id>"` on the ledger row
  (ADR-0040 §11) so a reader can tell a domain debit from the gateway
  and instance lines without a second `EntryReason`.
  """

  use Ash.Resource.Change

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.Wallet
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Repo

  require Ash.Query

  @month_useconds Decimal.new(2_629_746_000_000)
  @micros_per_cent Decimal.new(10_000)

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      settle(record)
    end)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (wallet lock + anchor writes)
  def atomic?, do: false

  # Leaving the serving arms: bill the interval actually served, then
  # close the window. Parking without billing would drop served time;
  # leaving it open would bill the whole unobserved gap in arrears on
  # recovery (the gateway's park, moved to the only honest end a
  # domain row has: this tick).
  defp park_anchor(%AccessDomain{metering_since: nil} = fresh), do: {:ok, fresh}

  defp park_anchor(%AccessDomain{} = fresh) do
    with {:ok, wallet} <- ensure_wallet(fresh),
         :ok <- settle_interval(fresh, wallet) do
      advance(fresh, nil)
    end
  end

  defp ensure_wallet(%AccessDomain{organization_id: org_id}) do
    Billing.ensure_wallet(%Organization{id: org_id})
  end

  defp settle_interval(%AccessDomain{} = fresh, %Wallet{} = wallet) do
    usecs = usecs_between(fresh.metering_since, DateTime.utc_now())
    micros = prorate(AccessDomain.monthly_cents(), usecs)
    post_debit(wallet, fresh, micros)
  end

  defp settle(%AccessDomain{} = record) do
    result =
      Repo.transaction(fn ->
        org = %Organization{id: record.organization_id}

        with {:ok, wallet} <- Billing.ensure_wallet(org),
             :ok <- lock_wallet(wallet),
             {:ok, fresh} <- fresh_domain(record),
             {:ok, updated} <- settle_fresh(fresh, wallet) do
          updated
        else
          # coveralls-ignore-start - defensive: wallet provisioning /
          # locking / the re-read only fail on a DB failure; nothing
          # committed, the worker's retry re-enters cleanly
          {:error, reason} ->
            Repo.rollback(reason)
            # coveralls-ignore-stop
        end
      end)

    case result do
      {:ok, domain} ->
        {:ok, domain}

      # coveralls-ignore-start - defensive: rollback only fires from the
      # arms above; a settle failure is an Oban retry, never a lost interval
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  defp lock_wallet(%Wallet{} = wallet) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [wallet.id])
    :ok
  end

  defp fresh_domain(%AccessDomain{} = record) do
    result =
      AccessDomain
      |> Ash.Query.filter(id == ^record.id)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one(authorize?: false)

    case result do
      # coveralls-ignore-start - race only: the row removed between the
      # worker's read and this one. Sequential tests cannot interleave it.
      {:ok, nil} ->
        {:ok, record}

      # coveralls-ignore-stop

      {:ok, domain} ->
        {:ok, domain}

      # coveralls-ignore-start - defensive: not simulatable under the sandbox
      {:error, reason} ->
        Repo.rollback(reason)
        # coveralls-ignore-stop
    end
  end

  # The accrual arms, re-checked against the COMMITTED row: the
  # scheduler's query is the suggestion, this re-check is the rule —
  # a settling row must never bill a domain that is not serving.
  defp settle_fresh(%AccessDomain{kind: :custom, state: state} = fresh, %Wallet{} = wallet)
       when state in [:verified, :needs_attention] do
    case fresh do
      %AccessDomain{metering_since: nil} = fresh ->
        # First tick (or first after resume): open the window, bill
        # nothing from the epoch.
        advance(fresh, DateTime.utc_now())

      %AccessDomain{} = fresh ->
        now = DateTime.utc_now()
        usecs = usecs_between(fresh.metering_since, now)
        micros = prorate(AccessDomain.monthly_cents(), usecs)

        with :ok <- post_debit(wallet, fresh, micros),
             {:ok, updated} <- advance(fresh, now) do
          {:ok, updated}
        else
          # coveralls-ignore-start - defensive: debit + anchor share this
          # transaction; failure rolls back both (DB failure only)
          {:error, reason} ->
            Repo.rollback(reason)
            # coveralls-ignore-stop
        end
    end
  end

  # Anything else (:pending, :failed, :suspended, :platform): not
  # serving the owner a billed domain — park whatever window a race
  # left open.
  defp settle_fresh(%AccessDomain{} = fresh, _wallet), do: park_anchor(fresh)

  defp usecs_between(from, to), do: max(DateTime.diff(to, from, :microsecond), 0)

  # Integer micro-cents, floored — the same rounding as the gateway
  # settle's prorate. The floored sub-µ¢ fraction is discarded (too small
  # for the ledger's unit); only the wallet's sub-CENT carryover pools.
  defp prorate(cents, usecs) do
    cents
    |> Decimal.new()
    |> Decimal.mult(@micros_per_cent)
    |> Decimal.mult(usecs)
    |> Decimal.div(@month_useconds)
    |> Decimal.round(0, :floor)
    |> Decimal.to_integer()
  end

  # Zero accrued: no ledger row (the instance settle's stance). The
  # anchor still advances.
  defp post_debit(_wallet, _domain, micros) when micros <= 0, do: :ok

  defp post_debit(%Wallet{} = wallet, %AccessDomain{} = domain, micros) do
    # The `fields` map rides PostEntry onto the ledger row: the subject
    # is the domain's attribution marker (ADR-0040 §11). `reason:
    # :usage` keeps one consumption dimension (the reconcilability
    # stance).
    case Billing.debit_wallet(wallet, micros,
           reason: :usage,
           fields: %{subject: "access-domain:#{domain.id}"}
         ) do
      {:ok, _entry_or_accrued} ->
        :ok

      # coveralls-ignore-start - defensive: posting failure = DB failure
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  defp advance(%AccessDomain{} = fresh, now) do
    result =
      fresh
      |> Ash.Changeset.for_update(:settle_anchors, %{metering_since: now}, authorize?: false)
      |> Ash.update(authorize?: false, return_notifications?: true)

    case result do
      {:ok, domain, _notifications} ->
        {:ok, domain}

      # coveralls-ignore-start - defensive: DB write failure
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end
end
