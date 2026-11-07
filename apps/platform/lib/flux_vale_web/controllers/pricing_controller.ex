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
  alias FluxVale.Pricing
  alias FluxValeWeb.Seo

  @pricing_description "Prices follow the resources you choose. Estimate your monthly cost with the live calculator."

  def show(conn, _params) do
    conn
    |> assign(:page_title, "Pricing · FluxVale")
    |> assign(:page_description, @pricing_description)
    |> assign(:canonical_path, "/pricing")
    |> assign(:welcome_grant_cents, Accounts.welcome_grant_cents())
    |> assign(:json_ld, json_ld())
    |> render(:show)
  end

  # The pricing page's Product block (the launch SEO audit lean):
  # shaped like Google's product rich result, carrying only numbers the
  # page itself shows — the ladder floor is the same "from" price the
  # landing band and catalog cards render (Pricing.from_price_cents/0).
  # No seeded floor, no honest price claim: the assign is nil and the
  # template skips the script, never a guessed price.
  defp json_ld do
    case Pricing.from_price_cents() do
      nil ->
        nil

      floor_cents ->
        Jason.encode!(
          %{
            "@context" => "https://schema.org",
            "@type" => "Product",
            "name" => "FluxVale managed cloud platform",
            "description" => @pricing_description,
            "image" => Seo.canonical_origin() <> Seo.default_og_image_path(),
            "url" => Seo.canonical_origin() <> "/pricing",
            "brand" => %{"@type" => "Brand", "name" => "FluxVale"},
            "offers" => %{
              "@type" => "AggregateOffer",
              "lowPrice" => usd_amount(floor_cents),
              "priceCurrency" => "USD"
            }
          },
          escape: :html_safe
        )
    end
  end

  # Schema.org wants a bare decimal ("5.00"), not the display "$5.00".
  defp usd_amount(cents), do: :erlang.float_to_binary(cents / 100, decimals: 2)
end
