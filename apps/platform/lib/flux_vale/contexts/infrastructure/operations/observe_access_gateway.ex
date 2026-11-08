defmodule FluxVale.Infrastructure.Operations.ObserveAccessGateway do
  @moduledoc """
  The observed-state write for a gateway (ADR-0039 §2): read the
  provider's view and land it on the row.

  This is the **only** promoter to `:active` — every other action lands
  `:provisioning`, because none of them has seen the cluster. Keeping
  one observer means the panel's badge can never claim a join the
  cluster has not reported.

  Transitions, all idempotent:

  - observed `:active` from anything but `:suspended` → `:active`,
    clears the attention clock, arms the settlement anchor if the row
    had none (the first observation after create — the settle trigger's
    `where` is `:active`, so this is what turns billing on);
  - observed `:active` on a row already `:active` re-reads the committed
    row: if it still carries the settled shape (`:active`, no attention
    clock, both anchors set, the settled message), the fresh row is
    returned with **no write and no broadcast** — the minute tick is a
    no-op instead of a row write per gateway per minute;
  - observed `:needs_attention` from `:active`/`:provisioning` →
    `:needs_attention` (stamps the clock once, on entry);
  - observed `:provisioning` → left alone (the objects are still
    landing); no write, no clock.

  The quiet arm is safe because a skipped write cannot clobber: it only
  fires after comparing the observation against the **committed** row,
  and it publishes nothing (Ash's PubSub notifier fires on update). The
  old "already active, nothing to do" shortcut's bug was not the
  absence of a write — it was deciding from the stale struct it already
  held, with no comparison to the committed row, so a concurrent
  suspend went unseen and the caller got the stale struct back. Here
  every divergent field (or a moved state) falls through to the filtered
  write below, which still refuses a row another writer moved.

  `:suspended` is never overridden by an observation: a scaled-to-zero
  gateway observes as "not serving" and the row's suspended state is
  the authority (the balance, not the cluster, decides that).

  **Every write is conditional on the state it read.** The observation
  is inherently stale — it is a snapshot of the row taken before a
  cluster round trip — so a blind `Ash.update` can land state that a
  concurrent writer has already revised. The concrete hazard: the
  observer reads `:active`, reads the Deployment, the ladder's Suspend
  commits `:suspended` (anchor parked), and then the blind write lands
  `:active` and **reopens the anchor** — a scaled-to-zero gateway
  billing as active until the next hourly sweep. The status guards above
  cannot catch it, because they inspect the same stale record.

  So each write carries `expected_state` in its filter: Postgres refuses
  it if the row moved, Ash returns a `StaleRecord`, and `call/1`
  re-reads and re-decides against the committed row. Concurrent writers
  therefore converge instead of clobbering each other.
  """

  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider

  require Logger

  @settled_message "Connected to your tailnet"

  @spec call(AccessGateway.t()) :: {:ok, AccessGateway.t()} | {:error, term()}
  def call(%AccessGateway{} = gateway), do: apply_observation(gateway, 1)

  # One retry is enough: the second read is the committed row, and a
  # second StaleRecord means another writer kept moving it — the next
  # minute's tick re-decides, which is the correct owner for a row that
  # is changing under everyone.
  defp apply_observation(gateway, effort) do
    case observe(gateway) do
      {:error, reason} = error ->
        Logger.warning("Access gateway #{gateway.id} status read failed: #{inspect(reason)}")
        error

      {:ok, observed, status} ->
        gateway
        |> apply_status(observed, status)
        |> retry_on_stale(gateway, effort)
    end
  end

  # A StaleRecord means another writer moved the row between our read and
  # our write: re-read and decide again. A second one means the row is
  # genuinely contended, and the next minute's tick is the right owner.
  defp retry_on_stale({:error, %Ash.Error.Invalid{} = error}, gateway, effort) do
    if effort > 0 and stale_record?(error) do
      case AccessGateway.get_by_id(gateway.id, authorize?: false) do
        {:ok, fresh} ->
          apply_observation(fresh, effort - 1)

        # coveralls-ignore-start - race/defensive: the row was torn down
        # between the stale write and this re-read, or the read failed;
        # ExUnit can stage neither deterministically. Logged rather than
        # swallowed, and the next tick re-observes either way.
        {:error, reason} ->
          Logger.warning(
            "Access gateway #{gateway.id} re-read failed mid-retry; leaving the row untouched: " <>
              inspect(reason)
          )

          {:ok, gateway}
          # coveralls-ignore-stop
      end
    else
      {:error, error}
    end
  end

  defp retry_on_stale(result, _gateway, _effort), do: result

  defp observe(gateway) do
    case AccessProvider.impl_for(gateway).gateway_status(gateway) do
      {:ok, %{state: observed} = status} -> {:ok, observed, status}
      {:error, _reason} = error -> error
    end
  end

  defp stale_record?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  # The suspension owns the row (see moduledoc), and so does an in-flight
  # teardown: an observation must never write over either.
  defp apply_status(%AccessGateway{state: state} = gateway, _observed, _status)
       when state in [:suspended, :destroying] do
    {:ok, gateway}
  end

  # The quiet arm: the passed row is already :active, so re-read the
  # committed row and return it untouched when it matches the settled
  # shape. No write means no UPDATE and no PubSub notification (the
  # notifier fires on update), so the per-org topic stays quiet for an
  # unchanged gateway. Any divergence — a field or the state itself —
  # falls through to the filtered write, where `expected_state` is the
  # passed row's state: a concurrent suspend still trips StaleRecord and
  # the retry re-decides against the committed row.
  defp apply_status(%AccessGateway{state: :active} = gateway, :active, _status) do
    case AccessGateway.get_by_id(gateway.id, authorize?: false) do
      {:ok, %AccessGateway{} = fresh} ->
        if settled_active?(fresh), do: {:ok, fresh}, else: write_active(gateway)

      # coveralls-ignore-start - race/defensive: the row was torn down
      # between the observation read and this re-read, or the read failed;
      # ExUnit can stage neither deterministically. Logged rather than
      # swallowed, and the next tick re-observes either way.
      {:error, reason} ->
        Logger.warning(
          "Access gateway #{gateway.id} re-read failed; leaving the row untouched: " <>
            inspect(reason)
        )

        {:ok, gateway}
        # coveralls-ignore-stop
    end
  end

  # Observed :active from any other committed state: promote, clear the
  # attention clock, and arm any missing settlement anchors. The write is
  # filtered and cannot clobber a concurrent writer (see the moduledoc).
  defp apply_status(%AccessGateway{} = gateway, :active, _status) do
    write_active(gateway)
  end

  defp apply_status(%AccessGateway{state: :needs_attention} = gateway, :needs_attention, _status) do
    {:ok, gateway}
  end

  defp apply_status(%AccessGateway{} = gateway, :needs_attention, status) do
    write(
      gateway,
      %{
        state: :needs_attention,
        status_message: status.message,
        needs_attention_since: DateTime.utc_now()
      },
      gateway.state
    )
  end

  defp apply_status(%AccessGateway{} = gateway, _provisioning_or_unknown, _status) do
    {:ok, gateway}
  end

  # Anchors are only armed when the passed row has none. Settlement advances
  # `metering_since` without changing state (the `settle_anchors` write), so
  # the state filter cannot refuse an anchor write — writing a held anchor
  # back could rewind the cursor and re-bill a window. Omitting the field
  # leaves the committed advance intact.
  defp write_active(gateway) do
    attrs =
      %{state: :active, status_message: @settled_message, needs_attention_since: nil}
      |> arm_anchor(:metering_since, gateway.metering_since)
      |> arm_anchor(:provisioned_at, gateway.provisioned_at)

    write(gateway, attrs, gateway.state)
  end

  defp arm_anchor(attrs, _field, %DateTime{}), do: attrs
  defp arm_anchor(attrs, field, nil), do: Map.put(attrs, field, DateTime.utc_now())

  # The shape an observation can safely leave untouched: the row is
  # serving, nothing is asking for attention, both anchors are armed and
  # the copy is the settled one the :active write lands.
  defp settled_active?(%AccessGateway{} = gateway) do
    gateway.state == :active and
      is_nil(gateway.needs_attention_since) and
      not is_nil(gateway.metering_since) and
      not is_nil(gateway.provisioned_at) and
      gateway.status_message == @settled_message
  end

  # `update_state` accepts `metering_since` (it is the observed-state
  # funnel, and settlement's cursor rides it), so the write is one UPDATE.
  #
  # The filter is the whole point: `expected_state` is the state this
  # observation decided against, so a row another writer moved is refused
  # (StaleRecord) rather than silently overwritten. See the moduledoc.
  defp write(%AccessGateway{} = gateway, attrs, expected_state) do
    gateway
    |> Ash.Changeset.for_update(:update_state, attrs, authorize?: false)
    |> Ash.Changeset.filter(state: expected_state)
    |> Ash.update()
  end
end
