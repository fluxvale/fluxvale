defmodule FluxValeWeb.PricingHTML do
  @moduledoc """
  The public pricing page (#440): the calculator is the pricing
  surface, embedded as a child LiveView; the page renders the welcome
  grant from the controller's assigns and the billing-model copy as
  prose.
  """

  use FluxValeWeb, :html

  alias FluxVale.Pricing

  embed_templates("pricing_html/*")
end
