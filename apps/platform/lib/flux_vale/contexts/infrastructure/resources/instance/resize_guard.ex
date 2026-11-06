defmodule FluxVale.Infrastructure.Instance.ResizeGuard do
  @moduledoc """
  The resize's guard rail, in ONE change so the ordering is
  self-contained (do not rely on Ash's between-changes error
  semantics) — #493's rulings, checked in order:

  1. **Stopped-first**: only a `:stopped` instance resizes (the apply
     lands while stopped; the workload runs at the new size on next
     start — a running resize is rejected, never deferred). The
     pre-transaction check alone is not the fence: start/delete bump no
     `version`, so the settle's FOR UPDATE re-read re-checks at write
     time (step 5).
  2. **Effective allocation**: absent params keep the row's dimension
     (`get_attribute` falls back to the record; a crafted nil reads as
     absent, the derive's chosen/2 stance). An all-dims no-op is
     rejected — a no-op append is audit noise.
  3. **Storage is up-only**: a shrink is refused, naming both figures.
  4. **Capability-gated growth**: growing storage requires the
     cluster's default class to allow expansion (the live probe,
     `StorageExpansion.capable?/1`). `{:ok, false}` refuses with the
     product boundary; a probe ERROR refuses with "check failed — try
     again" — the resize never bills a capability it couldn't read,
     and never reads a flaky probe as a no.
  5. **Settle-before-flip**: all clean, the open interval is settled at
     the in-force rate inside a `before_action` — old rates are still
     on the row, so no hour straddles two prices. The hook runs inside
     the action's transaction (probed on Ash 3.32: in_transaction?,
     pre-write read shows the old row; the settle's nested
     Repo.transaction runs inline on the same connection, so its
     rollback fails the whole outer transaction), and practical
     atomicity is what the resize needs: a later failure rolls the
     settled interval back with the refused resize.

  The guard is the ONE allocation-resolution site: on the clean path it
  force-changes the effective (nil-rescued) dims onto the changeset,
  normalizing crafted nils to absent — ResizePricing prices the
  normalized changeset.
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.Instance.SettleUsage
  alias FluxVale.Infrastructure.Operations.StorageExpansion

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    data = changeset.data

    if data.status == :stopped do
      changeset
      |> check_effect_allocation()
      |> normalize_allocation()
      |> settle_open_interval()
    else
      Ash.Changeset.add_error(
        changeset,
        "cannot resize instance in #{data.status} state (must be stopped)"
      )
    end
  end

  # Normalizes crafted nils to absent — pricing reads the normalized
  # changeset, one resolution site (the check above already refused
  # no-ops; an errored changeset never writes, so only the clean path
  # force-changes).
  defp normalize_allocation(changeset) do
    if changeset.valid? do
      effective = effective_allocation(changeset)

      changeset
      |> Ash.Changeset.force_change_attribute(:cpu_cores, effective.cpu_cores)
      |> Ash.Changeset.force_change_attribute(:memory_mb, effective.memory_mb)
      |> Ash.Changeset.force_change_attribute(:storage_gb, effective.storage_gb)
    else
      changeset
    end
  end

  # The allocation this resize lands at: changed dims from the request,
  # the rest off the row.
  defp effective_allocation(changeset) do
    data = changeset.data

    %{
      cpu_cores: Ash.Changeset.get_attribute(changeset, :cpu_cores) || data.cpu_cores,
      memory_mb: Ash.Changeset.get_attribute(changeset, :memory_mb) || data.memory_mb,
      storage_gb: Ash.Changeset.get_attribute(changeset, :storage_gb) || data.storage_gb
    }
  end

  defp check_effect_allocation(changeset) do
    data = changeset.data
    effective = effective_allocation(changeset)

    cond do
      allocation_unchanged?(effective, data) ->
        Ash.Changeset.add_error(changeset, "allocation is unchanged")

      effective.storage_gb < data.storage_gb ->
        Ash.Changeset.add_error(
          changeset,
          "storage can never shrink (from #{data.storage_gb} GB to #{effective.storage_gb} GB)"
        )

      storage_growing?(effective, data) ->
        capability_refusal(changeset, data)

      true ->
        changeset
    end
  end

  defp allocation_unchanged?(effective, data) do
    Decimal.eq?(effective.cpu_cores, data.cpu_cores) and
      effective.memory_mb == data.memory_mb and
      effective.storage_gb == data.storage_gb
  end

  defp storage_growing?(effective, data), do: effective.storage_gb > data.storage_gb

  # Only {:ok, true} opens the gate; {:ok, false} and {:error, _}
  # refuse, with distinct copy — a capability the layer lacks is a
  # product boundary, a probe that failed is a "try again".
  defp capability_refusal(changeset, data) do
    case StorageExpansion.capable?(data) do
      {:ok, true} ->
        changeset

      {:ok, false} ->
        Ash.Changeset.add_error(changeset, "storage can't be expanded on this cluster yet")

      {:error, _reason} ->
        Ash.Changeset.add_error(changeset, "storage expansion check failed — try again")
    end
  end

  # Settle at the OLD rate before the pricing flip (no hour straddles
  # two prices, #493). The cursor advance is the idempotency arbiter
  # shared with the trigger settle. The settle's FOR UPDATE re-read
  # doubles as the write-time status fence (see the head check's
  # limitation below): start/delete bump no `version`, so the
  # optimistic lock can't fence them — a start committing between the
  # pre-transaction read and this transaction is caught here, and the
  # row lock holds until the resize commits, so nothing can start the
  # instance after the fence either.
  defp settle_open_interval(changeset) do
    Ash.Changeset.before_action(changeset, &settle_and_fence/1)
  end

  defp settle_and_fence(changeset) do
    outcome = SettleUsage.settle_now(changeset.data)
    fence_settled(changeset, outcome)
  end

  defp fence_settled(changeset, {:ok, settled}) do
    if settled.status == :stopped do
      changeset
    else
      Ash.Changeset.add_error(
        changeset,
        "cannot resize instance in #{settled.status} state (must be stopped)"
      )
    end
  end

  # defensive: settle errors are DB-failure class (its rollback arms —
  # the outage ExUnit can't stage); the outer transaction rolls the
  # settled interval back with the refused resize
  # coveralls-ignore-start
  defp fence_settled(changeset, {:error, reason}) do
    Ash.Changeset.add_error(
      changeset,
      "resize failed to settle the open interval: #{inspect(reason)}"
    )
  end

  # coveralls-ignore-stop

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (hooks)
  def atomic?, do: false
end
