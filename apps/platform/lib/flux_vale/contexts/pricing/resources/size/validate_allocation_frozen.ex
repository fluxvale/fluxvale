defmodule FluxVale.Pricing.Size.ValidateAllocationFrozen do
  @moduledoc """
  A size's allocation freezes while versions point at it (#125).

  The version-side half of the coherence contract lives in
  `FluxVale.Catalog.AppVersion.ValidateSizeMatchesAllocation` (a version's
  defaults must equal its recommended size). This is the size-side half:
  repricing (cents) is free — the whole point of prices-as-data — but an
  AshAdmin reallocation of a referenced size would silently fork every
  referencing version's billing envelope from its provisioning quota in
  one write. Rejected: re-point or retire the versions first, then move
  the size.

  authorize?: false on the reference probe: a data-integrity check, not
  an authorization decision (see the version-side validation).
  """

  use Ash.Resource.Validation

  alias Ash.Resource.Validation
  alias FluxVale.Catalog.AppVersion

  @impl Validation
  def init(opts), do: {:ok, opts}

  @impl Validation
  def validate(changeset, _opts, _context) do
    if allocation_changing?(changeset) and referenced?(changeset.data.id) do
      {:error,
       field: :cpu_cores, message: "allocation is frozen while versions reference this size"}
    else
      :ok
    end
  end

  # Only a changed dimension trips the freeze — a cents-only reprice is
  # the admin path this resource exists for.
  defp allocation_changing?(changeset) do
    cpu = get(changeset, :cpu_cores)
    memory_mb = get(changeset, :memory_mb)
    storage_gb = get(changeset, :storage_gb)

    not Decimal.eq?(cpu, changeset.data.cpu_cores) or
      memory_mb != changeset.data.memory_mb or
      storage_gb != changeset.data.storage_gb
  end

  defp get(changeset, field), do: Ash.Changeset.get_argument_or_attribute(changeset, field)

  defp referenced?(size_id) do
    AppVersion
    |> Ash.Query.filter(recommended_size_id == ^size_id)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> Enum.any?()
  end
end
