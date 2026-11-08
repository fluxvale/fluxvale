defmodule FluxVale.Catalog.AppVersion.ValidateSizeMatchesAllocation do
  @moduledoc """
  Keeps the two statements of a version's compute from forking
  (#125, storage decoupled by #558): the
  `default_cpu_cores`/`default_memory_mb` blueprint (what
  provisioning grants, `DeriveFromAppVersion`) and the
  `recommended_size` compute class (what billing prices) must
  describe the same CPU + memory shape. Storage is the version's own
  honest per-app default — priced per GB on its axis, never pinned to
  the size. Runs on every create/update, so neither side can drift —
  including a defaults-only edit that leaves the size stale.

  authorize?: false on the size lookup: this is a data-integrity check,
  not an authorization decision — the caller's write was already gated
  by policy; the validation only needs the referenced row.

  ## Concurrency posture (#543)

  The size row is read under `FOR SHARE` inside the action's
  transaction (`before_action?` on create/update — at changeset time
  the lock would evaporate at statement end). The size-side half
  locks the same row `FOR UPDATE` before its freeze probe, so a
  reallocation in flight when this write starts holds the lock
  through its commit: this read waits, then sees the committed
  envelope and compares against that — never a stale one. `FOR SHARE`
  rather than `FOR UPDATE` because this side only reads the row: it
  still conflicts with the size side's `FOR UPDATE` and with the size
  UPDATE's own row lock (mutual exclusion with reallocation, which is
  the invariant), but two version writes pointing at one size can
  proceed concurrently. Neither side takes any other lock on the
  other's tables, so there is no ordering discipline to maintain
  between the halves.
  """

  use Ash.Resource.Validation

  alias Ash.Resource.Validation
  alias FluxVale.Pricing.Size

  @impl Validation
  def init(opts), do: {:ok, opts}

  @impl Validation
  def validate(changeset, _opts, _context) do
    size_id = Ash.Changeset.get_argument_or_attribute(changeset, :recommended_size_id)

    # present/1 owns requiredness; an unknown id is the FK's error.
    if size_id do
      case shared_size(size_id) do
        [size] -> validate_match(changeset, size)
        [] -> :ok
      end
    else
      :ok
    end
  end

  defp shared_size(size_id) do
    Size
    |> Ash.Query.filter(id == ^size_id)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read!(authorize?: false)
  end

  defp validate_match(changeset, size) do
    cpu = Ash.Changeset.get_argument_or_attribute(changeset, :default_cpu_cores)
    memory_mb = Ash.Changeset.get_argument_or_attribute(changeset, :default_memory_mb)

    if Decimal.eq?(size.cpu_cores, cpu) and size.memory_mb == memory_mb do
      :ok
    else
      {:error, field: :recommended_size_id, message: "must match the version's compute defaults"}
    end
  end
end
