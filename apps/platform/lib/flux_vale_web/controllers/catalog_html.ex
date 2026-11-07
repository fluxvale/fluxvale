defmodule FluxValeWeb.CatalogHTML do
  @moduledoc """
  The public catalog pages (#164): SSR mirrors of the authenticated
  CatalogLive browse — the programmatic-SEO surface anonymous visitors
  and crawlers read.
  """

  use FluxValeWeb, :html

  embed_templates("catalog_html/*")

  # ADR-0028's live estimate. #558: the recommended compute class's
  # rate plus the storage axis at the version's own default — priced
  # through Pricing.version_rates/1, never the size row alone (its
  # monthly rate carries no storage). Hidden rather than crash on a
  # sizeless version: pre-#125 rows heal through seed convergence, not
  # a backfill. Mirrors CatalogLive.Show's price badge.
  def price_badge(assigns) do
    assigns = assign(assigns, :rates, FluxVale.Pricing.version_rates(assigns.version))

    ~H"""
    <.badge :if={@rates} tone="primary" data-testid={"price-#{@version.version}"}>
      {FluxVale.Pricing.format_monthly_rate(@rates.monthly_cents)}
    </.badge>
    """
  end

  # #398: the storage-only fee beside the running rate — ADR-0028 §2,
  # in the /pricing table's "%{rate}/mo while stopped" idiom. #558: it
  # is the storage axis alone, from the same version_rates read. Hidden
  # with the price badge on a sizeless version.
  def stopped_rate(assigns) do
    assigns = assign(assigns, :rates, FluxVale.Pricing.version_rates(assigns.version))

    ~H"""
    <.badge :if={@rates} data-testid={"stopped-price-#{@version.version}"}>
      {gettext("%{rate}/mo while stopped",
        rate: FluxVale.Pricing.format_usd(@rates.stopped_monthly_cents)
      )}
    </.badge>
    """
  end

  defp sort_by_name(apps), do: Enum.sort_by(apps, & &1.name)
end
