defmodule FluxVale.TestSupport.PricingFixtures do
  @moduledoc """
  Preconditions for Pricing-surface tests: Size rows built through the
  create action (`authorize?: false`, mirroring the seeds' bootstrap
  posture), so the suite fails loudly when the create contract changes.
  """

  alias FluxVale.Pricing.Size

  @doc """
  A Size row through the create action. Defaults stand in for a mid
  ladder rung; pass overrides for the rates/allocation under test.
  """
  @spec size!(map()) :: Size.t()
  def size!(attrs \\ %{}) do
    n = System.unique_integer()

    defaults = %{
      slug: "test-#{n}",
      cpu_cores: Decimal.new("1"),
      memory_mb: 1024,
      monthly_cents: 500
    }

    defaults
    |> Map.merge(Map.new(attrs))
    |> Size.create!(authorize?: false)
  end
end
