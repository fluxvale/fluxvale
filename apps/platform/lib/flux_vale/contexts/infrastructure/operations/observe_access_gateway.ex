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
  """

  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider

  require Logger

  @spec call(AccessGateway.t()) :: {:ok, AccessGateway.t()} | {:error, term()}
  def call(%AccessGateway{} = gateway) do
    case AccessProvider.impl_for(gateway).gateway_status(gateway) do
      {:ok, %{state: observed} = status} ->
        apply_status(gateway, observed, status)

      {:error, reason} = error ->
        Logger.warning("Access gateway #{gateway.id} status read failed: #{inspect(reason)}")
        error
    end
  end

  # The suspension owns the row (see moduledoc), and so does an in-flight
  # teardown: an observation must never write over either.
  defp apply_status(%AccessGateway{state: state} = gateway, _observed, _status)
       when state in [:suspended, :destroying] do
    {:ok, gateway}
  end

  defp apply_status(%AccessGateway{} = gateway, :active, _status) do
    if gateway.state == :active and not is_nil(gateway.metering_since) do
      {:ok, gateway}
    else
      write(gateway, %{
        state: :active,
        status_message: "Connected to your tailnet",
        needs_attention_since: nil,
        metering_since: gateway.metering_since || DateTime.utc_now(),
        provisioned_at: gateway.provisioned_at || DateTime.utc_now()
      })
    end
  end

  defp apply_status(%AccessGateway{state: :needs_attention} = gateway, :needs_attention, _status) do
    {:ok, gateway}
  end

  defp apply_status(%AccessGateway{} = gateway, :needs_attention, status) do
    write(gateway, %{
      state: :needs_attention,
      status_message: status.message,
      needs_attention_since: DateTime.utc_now()
    })
  end

  defp apply_status(%AccessGateway{} = gateway, _provisioning_or_unknown, _status) do
    {:ok, gateway}
  end

  # `update_state` accepts `metering_since` (it is the observed-state
  # funnel, and settlement's cursor rides it), so the write is one UPDATE.
  defp write(%AccessGateway{} = gateway, attrs) do
    gateway
    |> Ash.Changeset.for_update(:update_state, attrs, authorize?: false)
    |> Ash.update()
  end
end
