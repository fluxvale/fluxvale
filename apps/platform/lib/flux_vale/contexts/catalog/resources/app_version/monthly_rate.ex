defmodule FluxVale.Catalog.AppVersion.MonthlyRate do
  @moduledoc """
  The version's recommended running rate in whole cents (#765) — the
  same compute-plus-storage figure the catalog page renders through
  `FluxVale.Pricing.version_rates/1`.

  A read-only calculation on the version projection so the MCP agent
  handoff can quote a cost before deploying. A version with no
  recommended size reads nil (the unpriced-drift shape); billing never
  guesses, and neither does the prompt.
  """

  use Ash.Resource.Calculation

  @impl Ash.Resource.Calculation
  def load(_query, _opts, _context), do: [recommended_size: [:monthly_cents]]

  @impl Ash.Resource.Calculation
  def calculate(records, _opts, _context) do
    Enum.map(records, fn version ->
      case FluxVale.Pricing.version_rates(version) do
        nil -> nil
        rates -> rates.monthly_cents
      end
    end)
  end
end
