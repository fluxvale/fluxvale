defmodule FluxVale.Infrastructure.Instance.ResizePricing do
  @moduledoc """
  The resize's re-pricing (#493): the allocation priced through
  `Instance.PricingSnapshot.snapshot/3` — the ONE choice the create
  shares — so resize cents are identical to destroy-and-recreate, with
  a FRESH 1-year clock (the old clock dies with the old allocation).

  The guard normalizes the era's allocation (its clean path
  force-changes the effective, nil-rescued dims); the pricing prices
  it — reading the normalized changeset, never re-deriving, so there is
  one resolution site and pricing only sets the four pricing attributes
  (size_id, both cents, the clock).

  The version loads `authorize?: false` — the derive's read posture
  (catalog rows are signed-in-readable; the resize's own policy already
  gated the caller).
  """

  use Ash.Resource.Change

  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Infrastructure.Instance.PricingSnapshot

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    data = changeset.data

    # Guaranteed nil-free: the guard force-changed the effective dims
    # before this change ran.
    effective = %{
      cpu_cores: Ash.Changeset.get_attribute(changeset, :cpu_cores),
      memory_mb: Ash.Changeset.get_attribute(changeset, :memory_mb),
      storage_gb: Ash.Changeset.get_attribute(changeset, :storage_gb)
    }

    case Ash.get(AppVersion, data.app_version_id, authorize?: false) do
      {:ok, version} ->
        pricing = PricingSnapshot.snapshot(effective, version, DateTime.utc_now())

        changeset
        |> Ash.Changeset.force_change_attribute(:size_id, pricing.size_id)
        |> Ash.Changeset.force_change_attribute(
          :grandfathered_monthly_cents,
          pricing.monthly_cents
        )
        |> Ash.Changeset.force_change_attribute(
          :grandfathered_stopped_monthly_cents,
          pricing.stopped_monthly_cents
        )
        |> Ash.Changeset.force_change_attribute(:grandfathered_until, pricing.grandfathered_until)

      # The guard already normalized an actionable allocation off the
      # row; a vanished version is the create's own error shape,
      # mirrored.
      # coveralls-ignore-start - defensive: the FK forbids deleting a
      # version a live instance points at
      {:error, _error} ->
        Ash.Changeset.add_error(changeset,
          field: :app_version_id,
          message: "selected app version not found"
        )

        # coveralls-ignore-stop
    end
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (reads another table)
  def atomic?, do: false
end
