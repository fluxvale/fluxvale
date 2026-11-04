defmodule FluxValeWeb.PricingHTML do
  @moduledoc """
  The public pricing page (#396): the published rate table and the
  add-on services render from the controller's assigns (Size rates,
  add-on accessors, welcome grant); the billing-model copy is prose.
  """

  use FluxValeWeb, :html

  alias FluxVale.Pricing

  embed_templates("pricing_html/*")
end
