defmodule FluxVale.Pricing.Size.ValidateAllocationFrozen do
  @moduledoc """
  A size's compute freezes while versions point at it (#125, storage
  decoupled by #558).

  The version-side half of the coherence contract lives in
  `FluxVale.Catalog.AppVersion.ValidateSizeMatchesAllocation` (a
  version's compute defaults must equal its recommended size). This is
  the size-side half: repricing (cents) is free — the whole point of
  prices-as-data — but a compute reallocation of a referenced size
  from an admin surface would silently fork every referencing
  version's billing envelope from its provisioning quota in one
  write. Rejected: re-point or retire the versions first, then move
  the size. (The operator edit surface is the console at
  /admin/catalog, which explains this validation instead of
  bypassing it; the generated admin at /admin/ash is the debug
  fallback.)

  authorize?: false on the reference probe: a data-integrity check, not
  an authorization decision (see the version-side validation).

  ## Concurrency posture (#543)

  The size row is locked FOR UPDATE and re-read *before* anything
  else, inside the action's transaction (`before_action?` on the
  update action — at changeset time the lock would evaporate at
  statement end). The freeze verdict then compares against the locked
  row's committed values (not the caller's pre-image, which can go
  stale mid-action) and probes `app_versions` while holding the lock.
  The version-side half takes a `FOR SHARE` on the same row inside its
  own transaction, so whichever of the two writes commits first, the
  other re-checks against committed state — the probe can no longer
  race an in-flight re-point. Neither side takes any other lock on
  the other's tables, so there is no ordering discipline to maintain
  between the halves.

  The lock is taken even for reprices: the row is being written by
  the same action anyway, so the earlier acquisition adds no
  contention — and a forced no-op-looking write cannot skip the probe.
  (An atomic-expression write to cpu/memory would still bypass this
  validation entirely; no such writer exists — the action is
  `require_atomic? false` and admin/seeds write plain attributes. The
  first atomic writer of size compute revisits this.)
  """

  use Ash.Resource.Validation

  alias Ash.Resource.Validation
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Pricing.Size

  @impl Validation
  def init(opts), do: {:ok, opts}

  @impl Validation
  def validate(changeset, _opts, _context) do
    case locked_size(changeset.data.id) do
      # The row vanished mid-action (a concurrent destroy of an
      # unreferenced size) — the update itself fails on the missing
      # row; there is nothing left to freeze.
      # coveralls-ignore-next-line
      [] ->
        :ok

      [size] ->
        if allocation_changing?(changeset, size) and referenced?(size.id) do
          {:error,
           field: :cpu_cores, message: "compute is frozen while versions reference this size"}
        else
          :ok
        end
    end
  end

  defp locked_size(size_id) do
    Size
    |> Ash.Query.filter(id == ^size_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read!(authorize?: false)
  end

  # Only a changed compute dimension trips the freeze — a cents-only
  # reprice is the admin path this resource exists for. Compares the
  # incoming value (when the changeset carries one) against the locked
  # row's committed value; an absent dimension reads as unchanged.
  defp allocation_changing?(changeset, size) do
    cpu = effective(changeset, :cpu_cores, size.cpu_cores)
    memory_mb = effective(changeset, :memory_mb, size.memory_mb)

    not Decimal.eq?(cpu, size.cpu_cores) or
      memory_mb != size.memory_mb
  end

  defp effective(changeset, field, current) do
    case Ash.Changeset.fetch_change(changeset, field) do
      {:ok, value} -> value
      :error -> current
    end
  end

  # Runs while the transaction already holds the row lock — the
  # probe's verdict is true at commit time, not just at read time
  # (#543).
  defp referenced?(size_id) do
    AppVersion
    |> Ash.Query.filter(recommended_size_id == ^size_id)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> Enum.any?()
  end
end
