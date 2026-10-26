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
  - observed `:needs_attention` from `:active`/`:provisioning` →
    `:needs_attention` (stamps the clock once, on entry);
  - observed `:provisioning` → left alone (the objects are still
    landing); no write, no clock.

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

        # The row was torn down between the stale write and this re-read.
        # Nothing to observe; the teardown owns it from here.
        # coveralls-ignore-next-line race only: teardown winning mid-retry
        {:error, _gone} ->
          {:ok, gateway}
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

  # Always writes (the instance reconciler's stance: an observation is a
  # write, and it bumps updated_at even when nothing changed). The old
  # in-memory "already active, nothing to do" shortcut was the bug's other
  # half: deciding from the STALE record it skipped the write entirely, so
  # no filter could refuse it and the caller got the stale struct back while
  # the real row said :suspended. The filtered write is what makes the
  # decision safe, so the decision has to be the write.
  defp apply_status(%AccessGateway{} = gateway, :active, _status) do
    write(
      gateway,
      %{
        state: :active,
        status_message: "Connected to your tailnet",
        needs_attention_since: nil,
        metering_since: gateway.metering_since || DateTime.utc_now(),
        provisioned_at: gateway.provisioned_at || DateTime.utc_now()
      },
      gateway.state
    )
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
