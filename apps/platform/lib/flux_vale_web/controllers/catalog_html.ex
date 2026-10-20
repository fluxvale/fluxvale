defmodule FluxValeWeb.CatalogHTML do
  @moduledoc """
  The public catalog pages (#164): SSR mirrors of the authenticated
  CatalogLive browse — the programmatic-SEO surface anonymous visitors
  and crawlers read.
  """

  use FluxValeWeb, :html

  embed_templates "catalog_html/*"

  # ADR-0028's live estimate. Hidden rather than crash on a nil size:
  # pre-#125 rows heal through seed convergence, not a backfill.
  # Mirrors CatalogLive.Show's price badge.
  def price_badge(assigns) do
    ~H"""
    <span
      :if={@version.recommended_size}
      class="badge badge-primary badge-outline"
      data-testid={"price-#{@version.version}"}
    >
      {FluxVale.Pricing.format_usd(@version.recommended_size.monthly_cents)}/mo
    </span>
    """
  end

  defp sort_by_name(apps), do: Enum.sort_by(apps, & &1.name)
end
