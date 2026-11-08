defmodule FluxVale.Infrastructure.Instance.StorageGrowthGuard do
  @moduledoc """
  The online storage-only growth's guard (#250), in ONE change so the
  ordering is self-contained (do not rely on Ash's between-changes error
  semantics) — `ResizeGuard`'s steps 2–5 minus the stopped-first fence:

  1. **Live instance**: only `:deleting` and `:lost` refuse — growth is an
     online storage-layer operation, so `:running`, `:stopped` and
     `:sleeping` are all legal (ADR-0036's status semantics: a sleeping
     row still owns its PVC and bills storage-only). The pre-transaction
     check alone is not the fence: start/delete bump no `version`, so the
     settle's FOR UPDATE re-read re-checks at write time (step 5).
  2. **Effective allocation**: the request's storage over the row's
     CPU/RAM (a crafted nil reads as absent, the derive's chosen/2
     stance). A no-op is rejected naming both figures — a no-op append is
     audit noise.
  3. **Storage is up-only**: a shrink is refused, naming both figures.
  4. **Capability-gated growth**: the cluster's default class must allow
     expansion (the live probe, `StorageExpansion.capable?/1`).
     `{:ok, false}` refuses with the product boundary; a probe ERROR
     refuses with "check failed — try again" — the growth never bills a
     capability it couldn't read, and never reads a flaky probe as a no.
  5. **Settle-before-flip**: all clean, the open interval is settled at
     the in-force rate inside a `before_action` — old rates are still on
     the row, so no hour straddles two prices. The hook runs inside the
     action's transaction (the resize's probed semantics: the settle's
     nested Repo.transaction runs inline on the same connection, so its
     rollback fails the whole outer transaction), and the settle's FOR
     UPDATE re-read doubles as the write-time status fence.

  The guard is the ONE allocation-resolution site: it force-changes the
  effective triple — row CPU/RAM + the new storage — so ResizePricing
  reads one normalized changeset (pricing runs even beside a refused
  changeset, so the normalization cannot be conditional).
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Instance.SettleUsage
  alias FluxVale.Infrastructure.Operations.StorageExpansion

  @refused_statuses [:deleting, :lost]

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    %Instance{} = data = changeset.data

    # Normalize first: pricing runs even beside a refused changeset (Ash
    # accumulates change results), so it must always read a nil-free
    # allocation. A refused changeset never writes, so only the checks'
    # outcome decides the write.
    changeset = normalize_allocation(changeset)

    if data.status in @refused_statuses do
      Ash.Changeset.add_error(
        changeset,
        "cannot grow storage for an instance in #{data.status} state"
      )
    else
      changeset
      |> check_effective_allocation()
      |> settle_open_interval()
    end
  end

  # Normalizes crafted nils to absent — pricing reads the normalized
  # changeset, one resolution site.
  defp normalize_allocation(changeset) do
    effective = effective_allocation(changeset)

    changeset
    |> Ash.Changeset.force_change_attribute(:cpu_cores, effective.cpu_cores)
    |> Ash.Changeset.force_change_attribute(:memory_mb, effective.memory_mb)
    |> Ash.Changeset.force_change_attribute(:storage_gb, effective.storage_gb)
  end

  # The allocation this growth lands at: the new storage, CPU/RAM off the
  # row (this action never moves compute).
  defp effective_allocation(changeset) do
    %Instance{} = data = changeset.data

    %{
      cpu_cores: data.cpu_cores,
      memory_mb: data.memory_mb,
      storage_gb: Ash.Changeset.get_attribute(changeset, :storage_gb) || data.storage_gb
    }
  end

  defp check_effective_allocation(changeset) do
    %Instance{} = data = changeset.data
    effective = effective_allocation(changeset)

    cond do
      effective.storage_gb == data.storage_gb ->
        Ash.Changeset.add_error(
          changeset,
          "storage is unchanged (from #{data.storage_gb} GB to #{effective.storage_gb} GB)"
        )

      effective.storage_gb < data.storage_gb ->
        Ash.Changeset.add_error(
          changeset,
          "storage can never shrink (from #{data.storage_gb} GB to #{effective.storage_gb} GB)"
        )

      true ->
        capability_refusal(changeset, data)
    end
  end

  # Only {:ok, true} opens the gate; {:ok, false} and {:error, _} refuse,
  # with distinct copy — a capability the layer lacks is a product
  # boundary, a probe that failed is a "try again".
  #
  # A nil cluster is defensive (ResolveCluster pins one at create): there
  # is no capability to read, so it refuses like a failed probe rather
  # than guessing a yes.
  # coveralls-ignore-start
  defp capability_refusal(changeset, %Instance{cluster_id: nil}) do
    Ash.Changeset.add_error(changeset, "storage expansion check failed — try again")
  end

  # coveralls-ignore-stop
  defp capability_refusal(changeset, %Instance{cluster_id: cluster_id}) do
    case StorageExpansion.capable?(%{cluster_id: cluster_id}) do
      {:ok, true} ->
        changeset

      {:ok, false} ->
        Ash.Changeset.add_error(changeset, "storage can't be expanded on this cluster yet")

      {:error, _reason} ->
        Ash.Changeset.add_error(changeset, "storage expansion check failed — try again")
    end
  end

  # Settle at the OLD rate before the pricing flip (no hour straddles two
  # prices, #493). The cursor advance is the idempotency arbiter shared
  # with the trigger settle. The settle's FOR UPDATE re-read doubles as
  # the write-time status fence: start/delete bump no `version`, so the
  # optimistic lock can't fence them — a delete committing between the
  # pre-transaction read and this transaction is caught here, and the row
  # lock holds until the growth commits.
  defp settle_open_interval(changeset) do
    Ash.Changeset.before_action(changeset, &settle_and_fence/1)
  end

  defp settle_and_fence(changeset) do
    outcome = SettleUsage.settle_now(changeset.data)
    fence_settled(changeset, outcome)
  end

  defp fence_settled(changeset, {:ok, settled}) do
    if settled.status in @refused_statuses do
      Ash.Changeset.add_error(
        changeset,
        "cannot grow storage for an instance in #{settled.status} state"
      )
    else
      changeset
    end
  end

  # defensive: settle errors are DB-failure class (its rollback arms — the
  # outage ExUnit can't stage); the outer transaction rolls the settled
  # interval back with the refused growth
  # coveralls-ignore-start
  defp fence_settled(changeset, {:error, reason}) do
    Ash.Changeset.add_error(
      changeset,
      "storage growth failed to settle the open interval: #{inspect(reason)}"
    )
  end

  # coveralls-ignore-stop

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (hooks)
  def atomic?, do: false
end
