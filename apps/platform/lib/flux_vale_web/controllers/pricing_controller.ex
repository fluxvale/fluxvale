defmodule FluxValeWeb.PricingController do
  @moduledoc """
  The public pricing page (#440): the product's cost-truth surface, a
  single curve-priced calculator — resource sliders in, one total out
  (PikaPods pattern; the tiers left the page with #440's restructure).
  Anonymous-OK like the catalog (#164, ADR-00025). The interactive
  calculator renders in the page's marked section: the controller-
  embedded PricingCalculatorLive prices through price_allocation/1 and
  the service accessors directly, so no price literal ships in a
  template. The controller keeps only the SEO assigns and the welcome
  grant the billing band renders.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Accounts

  @pricing_description "Prices follow the resources you choose. Estimate your monthly cost with the live calculator."

  def show(conn, _params) do
    conn
    |> assign(:page_title, "Pricing · FluxVale")
    |> assign(:page_description, @pricing_description)
    |> assign(:canonical_path, "/pricing")
    |> assign(:welcome_grant_cents, Accounts.welcome_grant_cents())
    |> render(:show)
  end
end
