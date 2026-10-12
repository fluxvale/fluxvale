defmodule FluxVale.Catalog.AppVersion.ValidateSizeMatchesAllocation do
  @moduledoc """
  Keeps the two statements of a version's allocation from forking
  (#125): the `default_cpu_cores`/`default_memory_mb`/`default_storage_gb`
  blueprint (what provisioning grants, `DeriveFromAppVersion`) and the
  `recommended_size` envelope (what billing prices) must describe the
  same allocation. Runs on every create/update, so neither side can
  drift — including a defaults-only edit that leaves the size stale.

  authorize?: false on the size lookup: this is a data-integrity check,
  not an authorization decision — the caller's write was already gated
  by policy; the validation only needs the referenced row.
  """

  use Ash.Resource.Validation

  alias Ash.Resource.Validation

  @impl Validation
  def init(opts), do: {:ok, opts}

  @impl Validation
  def validate(changeset, _opts, _context) do
    size_id = Ash.Changeset.get_argument_or_attribute(changeset, :recommended_size_id)

    # present/1 owns requiredness; an unknown id is the FK's error.
    if size_id do
      case Ash.get(FluxVale.Pricing.Size, size_id, authorize?: false) do
        {:ok, size} -> validate_match(changeset, size)
        {:error, _not_found} -> :ok
      end
    else
      :ok
    end
  end

  defp validate_match(changeset, size) do
    cpu = Ash.Changeset.get_argument_or_attribute(changeset, :default_cpu_cores)
    memory_mb = Ash.Changeset.get_argument_or_attribute(changeset, :default_memory_mb)
    storage_gb = Ash.Changeset.get_argument_or_attribute(changeset, :default_storage_gb)

    if Decimal.eq?(size.cpu_cores, cpu) and size.memory_mb == memory_mb and
         size.storage_gb == storage_gb do
      :ok
    else
      {:error, field: :recommended_size_id, message: "must match the version's allocation"}
    end
  end
end
