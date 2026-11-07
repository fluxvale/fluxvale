defmodule FluxVale.Infrastructure.Operations.ResizePreview do
  @moduledoc """
  The resize panel's price preview (#493): what a resize WOULD snapshot
  for a candidate allocation — priced through the SAME `PricingSnapshot`
  choice the `:resize` action charges through, so the shown price is the
  charged price by construction (the deploy flow's invariant).

  `{:ok, nil}` is the unpriced arm — a sizeless recommendation at its
  defaults: the panel shows no price line and refuses to confirm (never
  bill a guess). A custom allocation always carries formula cents.
  """

  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Instance.PricingSnapshot

  @typedoc "The panel's preview: the rate figures a resize WOULD
  snapshot (running and stopped)."
  @type preview :: %{
          running_cents: non_neg_integer(),
          stopped_cents: non_neg_integer()
        }

  @doc """
  The preview for `allocation` (typed: Decimal cpu, integer memory and
  storage — the rung strings' decoded form) against the instance's
  version catalog, clocked now. The version loads `authorize?: false` —
  the resize family's posture (the member-gated action loads it the
  same way). A pricing read that raises (a long-lived page whose
  catalog moved under it) answers `{:error, term()}` — the panel hides
  the price line instead of crashing.
  """
  @spec call(Instance.t(), %{
          cpu_cores: Decimal.t(),
          memory_mb: integer(),
          storage_gb: integer()
        }) ::
          {:ok, preview()} | {:ok, nil} | {:error, term()}
  def call(instance, allocation) do
    version = Ash.load!(instance, :app_version, authorize?: false).app_version
    pricing = PricingSnapshot.snapshot(allocation, version, DateTime.utc_now())
    respond(pricing)
  rescue
    # The raise shape: a read inside the snapshot choice failing for a
    # row the catalog moved under. The stubbed-raise test pins this arm
    # end to end; {:error, _} is what the panel's :unavailable rides.
    error -> {:error, error}
  end

  # The unpriced arm: a sizeless recommendation snapshots all-nil — the
  # panel hides the price line and disables Continue. A custom
  # allocation always carries formula cents.
  defp respond(%{monthly_cents: nil}), do: {:ok, nil}

  defp respond(%{monthly_cents: running, stopped_monthly_cents: stopped}) do
    {:ok, %{running_cents: running, stopped_cents: stopped}}
  end
end
