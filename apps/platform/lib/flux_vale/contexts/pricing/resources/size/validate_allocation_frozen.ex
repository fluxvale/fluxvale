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

  The probe locks the size row FOR UPDATE *before* reading referencing
  versions, inside the action's transaction (`before_action?` on the
  update action — at changeset time the lock would evaporate at
  statement end). The version-side half locks the same row, so a
  re-point in flight when this write starts holds the lock through its
  commit: this probe waits, then sees the committed reference and
  rejects. Both halves take exactly one lock (the shared size row), so
  there is no lock ordering to get wrong and no deadlock to court.
  """

  use Ash.Resource.Validation

  alias Ash.Resource.Validation
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Pricing.Size

  @impl Validation
  def init(opts), do: {:ok, opts}

  @impl Validation
  def validate(changeset, _opts, _context) do
    if allocation_changing?(changeset) and referenced?(changeset.data.id) do
      {:error, field: :cpu_cores, message: "compute is frozen while versions reference this size"}
    else
      :ok
    end
  end

  # Only a changed compute dimension trips the freeze — a cents-only
  # reprice is the admin path this resource exists for.
  defp allocation_changing?(changeset) do
    cpu = get(changeset, :cpu_cores)
    memory_mb = get(changeset, :memory_mb)

    not Decimal.eq?(cpu, changeset.data.cpu_cores) or
      memory_mb != changeset.data.memory_mb
  end

  defp get(changeset, field), do: Ash.Changeset.get_argument_or_attribute(changeset, field)

  defp referenced?(size_id) do
    # Lock first, probe second: the lock is what makes the probe's
    # verdict true at commit time, not just at read time (#543).
    Size
    |> Ash.Query.filter(id == ^size_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read!(authorize?: false)

    AppVersion
    |> Ash.Query.filter(recommended_size_id == ^size_id)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> Enum.any?()
  end
end
