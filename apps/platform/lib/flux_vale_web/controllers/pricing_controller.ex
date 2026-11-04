defmodule FluxValeWeb.PricingController do
  @moduledoc """
  The public pricing page (#396): the product's cost-truth surface,
  resource-framed — prices follow the resources an app gets, never the
  app. Anonymous-OK like the catalog (#164, ADR-00025). Every price
  renders from the pricing ground truth at request time — the Size
  rows' public read (the rate table) and the config-backed accessors
  (gateway, custom domain, welcome grant) — so no price literal ships
  in a template. The interactive calculator mounts in the page's
  marked empty section in its own slice.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Accounts
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Pricing.Size

  @pricing_description "Per-instance monthly rates from a published size table, prepaid credits, billed hourly."

  def show(conn, _params) do
    sizes =
      Size
      |> Ash.Query.for_read(:read, %{}, actor: nil)
      |> Ash.Query.sort(:monthly_cents)
      |> Ash.read!()

    conn
    |> assign(:page_title, "Pricing · FluxVale")
    |> assign(:page_description, @pricing_description)
    |> assign(:canonical_path, "/pricing")
    |> assign(:sizes, sizes)
    |> assign(:gateway_monthly_cents, AccessGateway.monthly_cents())
    |> assign(:domain_monthly_cents, AccessDomain.monthly_cents())
    |> assign(:welcome_grant_cents, Accounts.welcome_grant_cents())
    |> render(:show)
  end
end
