defmodule FluxVale.BootInvariants do
  @moduledoc """
  The boot invariants readiness gates on (#175, ADR-0033): the
  required reference data an instance create needs — pricing sizes,
  catalog app versions, exactly one cluster row. The fleet's seed
  init container establishes all three on every deploy; this check is
  the loud backstop when they're missing anyway — Oct 20's prod
  booted "healthy" with empty `pricing_sizes` and `clusters` while
  every deploy failed invisibly.

  Reads run `authorize?: false`: probe-land has no actor, and this is
  global config, not actor-scoped data (the ResolveCluster posture).
  """

  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Pricing.Size

  @spec check :: :ok | {:error, [String.t()]}
  def check do
    errors = List.flatten([pricing(), catalog(), clusters()])

    case errors do
      [] -> :ok
      violations -> {:error, violations}
    end
  end

  # Each message names its invariant and its restore path — the error
  # log line is the operator's whole diagnosis.
  defp pricing do
    missing_reference_data(:pricing, Size)
  end

  defp catalog do
    missing_reference_data(:catalog, AppVersion)
  end

  defp missing_reference_data(invariant, resource) do
    # timeout: the probe's deadline is finite — a stalled count must
    # return, not hang the readiness response past it (#176 review).
    case Ash.count(resource, authorize?: false, timeout: 500) do
      {:ok, 0} ->
        ["#{invariant}: no rows — required reference data missing (bin/seed restores it)"]

      {:ok, _count} ->
        []

      # coveralls-ignore-start - count failure means the DB died
      # mid-probe; ready/2 gates on db_up? first, and ExUnit can't
      # kill the DB (AGENTS.md) — same untestable shape as db_up?'s
      # arms.
      {:error, _reason} ->
        ["#{invariant}: count failed — database error"]

        # coveralls-ignore-stop
    end
  end

  defp clusters do
    case Ash.count(Cluster, authorize?: false, timeout: 500) do
      {:ok, 1} ->
        []

      {:ok, count} ->
        [
          "clusters: #{count} rows (need exactly one) — bin/ensure-cluster creates the row; extras are removed in AshAdmin"
        ]

      # coveralls-ignore-start - same untestable-in-ExUnit failure
      # shape as above.
      {:error, _reason} ->
        ["clusters: count failed — database error"]

        # coveralls-ignore-stop
    end
  end
end
