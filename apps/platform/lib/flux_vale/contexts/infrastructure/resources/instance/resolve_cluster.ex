defmodule FluxVale.Infrastructure.Instance.ResolveCluster do
  @moduledoc """
  Pins `cluster_id` on create. M3 has exactly one cluster (the seeded
  `local` row, #72): zero rows is operator bring-up gap, more than one is
  the multi-cluster routing that arrives with ADR-0006/ADR-0016 — both
  fail loudly here rather than picking arbitrarily.

  Read with `authorize?: false`: cluster placement is global config, not
  actor-scoped data (the Cluster policy posture, #72).
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.Cluster

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    case Ash.read(Cluster, authorize?: false) do
      {:ok, [cluster]} ->
        Ash.Changeset.force_change_attribute(changeset, :cluster_id, cluster.id)

      {:ok, []} ->
        Ash.Changeset.add_error(changeset,
          field: :cluster_id,
          message: "no cluster is configured"
        )

      {:ok, _multiple} ->
        Ash.Changeset.add_error(changeset,
          field: :cluster_id,
          message: "cluster selection is not implemented for multiple clusters (ADR-0006)"
        )

      # defensive: cluster read DB failure (ExUnit can't kill the DB)
      # coveralls-ignore-start
      {:error, _error} ->
        Ash.Changeset.add_error(changeset, field: :cluster_id, message: "cluster lookup failed")
        # coveralls-ignore-stop
    end
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (reads another table)
  def atomic?, do: false
end
