defmodule FluxValeWeb.PricingControllerTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Pricing

  test "GET /pricing renders 200 for an anonymous visitor", %{conn: conn} do
    conn = get(conn, ~p"/pricing")

    assert conn.status == 200
    assert html_response(conn, 200) =~ "Prices follow the resources an app gets"
  end

  # #440: the calculator fills the mount point — the child LiveView's
  # SSR, so crawlers see the formed state: the default small rungs priced
  # through price_allocation, the app select, the sliders, and the
  # service toggles, plus the session div the client boots from.
  test "GET /pricing renders the calculator's SSR inside the mount point", %{conn: conn} do
    :ok = FluxVale.Seeds.seed_pricing!()

    conn = get(conn, ~p"/pricing")
    html = html_response(conn, 200)

    assert html =~ ~s(id="calculator")
    assert html =~ "Cost calculator"
    assert html =~ ~s(id="pricing-calculator")
    assert html =~ "data-phx-session"

    # The default state is small's rungs, priced through price_allocation
    # with no service toggled on — the hero total is the calculator's own
    # copy of the numbers.
    allocation = %{cpu_cores: Decimal.new("0.5"), memory_mb: 512, storage_gb: 10}
    priced = Pricing.price_allocation(allocation)

    assert html =~ Pricing.format_monthly_rate(priced.monthly_cents)
    assert html =~ "#{Pricing.format_usd(priced.stopped_monthly_cents)}/mo while stopped"
    assert html =~ "0.5 CPU · 512 MB · 10 GB"

    # The app select, the sliders, and the service toggles ride the SSR.
    assert html =~ ~s(id="calculator-app-select")
    assert html =~ "Choose an app"
    assert html =~ ~s(id="resource-cpu-cores")
    assert html =~ ~s(id="calculator-services-form")
  end

  # #440: the tiers left the page — the seeded slugs render nowhere, on
  # the full SSR (page chrome plus calculator). The opaque phx/CSRF
  # tokens are stripped first: random base64 could carry a slug at an
  # attribute edge by chance, which is noise, not rendered copy.
  test "GET /pricing renders no size names", %{conn: conn} do
    :ok = FluxVale.Seeds.seed_pricing!()

    html =
      conn
      |> get(~p"/pricing")
      |> html_response(200)
      |> strip_opaque_tokens()

    refute html =~ ~r/\b(micro|small|medium|standard|plus|pro)\b/i
    refute html =~ "size-chip"
  end

  # The service toggles price from the accessors — their flat rates show
  # as line items inside the calculator's SSR.
  test "GET /pricing renders the service line items and the free facts caption", %{conn: conn} do
    conn = get(conn, ~p"/pricing")
    html = html_response(conn, 200)

    gateway_rate = Pricing.format_usd(AccessGateway.monthly_cents())
    domain_rate = Pricing.format_usd(AccessDomain.monthly_cents())

    # The line items keep the #206 qualifier: the add-on rate reads
    # "+rate/mo ..., billed hourly" on the SSR surface too.
    gateway_line = "+#{gateway_rate}/mo per gateway, billed hourly"
    domain_line = "+#{domain_rate}/mo per verified domain, billed hourly"

    assert html =~ "Private access gateway"
    assert html =~ gateway_line
    assert html =~ "Custom domain"
    assert html =~ domain_line
    assert html =~ "Hostnames under fluxvale.app, public exposure, DNS, and resolution are free."
  end

  test "GET /pricing states the billing model from the accessors", %{conn: conn} do
    conn = get(conn, ~p"/pricing")
    html = html_response(conn, 200)

    welcome = Pricing.format_usd(Accounts.welcome_grant_cents())

    assert html =~ "New accounts start with #{welcome} in credits."
    assert html =~ "One credit is one US cent"
    assert html =~ "There are no subscriptions"
    assert html =~ "your apps stop running and their charges stop with them"
    assert html =~ "Stopped apps keep their storage fee"
    assert html =~ "negative for 30 days deletes your data"
    assert html =~ "warnings 7 days and 1 day before"
  end

  test "meta: branded title, description, canonical", %{conn: conn} do
    html =
      conn
      |> get(~p"/pricing")
      |> html_response(200)

    assert [_match, title] = Regex.run(~r{<title[^>]*>(.*)</title>}s, html)
    assert title == "Pricing · FluxVale"

    assert html =~
             ~s(name="description" content="Prices follow the resources you choose. Estimate your monthly cost with the live calculator.")

    assert html =~ ~s(rel="canonical" href="https://fluxvale.com/pricing")
  end

  # #396: the links — the public chrome's nav and footer both carry the
  # Pricing link. Whitespace-tolerant matching: the nav_link slot
  # renders with newlines around the label.
  test "GET /pricing carries the Pricing nav and footer links", %{conn: conn} do
    conn = get(conn, ~p"/pricing")
    html = html_response(conn, 200)

    body =
      html
      |> String.split("<body>")
      |> List.last()

    assert length(String.split(body, ~s(href="/pricing"))) - 1 == 2
    assert body =~ ~r/href="\/pricing"[^>]*>\s*Pricing\s*<\/a>/
  end

  defp strip_opaque_tokens(html) do
    # Class attributes are styling tokens, never copy (icon sizing alone
    # carries "-micro" fragments); the phx/CSRF values are random base64.
    # None of those are rendered text, and all can false-positive the
    # slug check, so only the markup's text survives them.
    without_view_tokens = Regex.replace(~r/data-phx-(session|static)="[^"]*"/, html, "")
    without_csrf = Regex.replace(~r/name="csrf-token" content="[^"]*"/, without_view_tokens, "")
    Regex.replace(~r/class="[^"]*"/, without_csrf, "")
  end
end
