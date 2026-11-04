defmodule FluxValeWeb.PricingControllerTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Pricing
  alias FluxVale.Pricing.Size
  alias FluxVale.TestSupport.PricingFixtures

  # The controller's read, mirrored: the same public read, same sort.
  defp published_sizes! do
    Size
    |> Ash.Query.for_read(:read, %{}, actor: nil)
    |> Ash.Query.sort(:monthly_cents)
    |> Ash.read!()
  end

  # First byte offset of a rate label in the response — the table (the
  # first DOM copy of every label) is what the sort assertion reads.
  defp offset(html, needle) do
    match = :binary.match(html, needle)
    elem(match, 0)
  end

  test "GET /pricing renders 200 for an anonymous visitor", %{conn: conn} do
    conn = get(conn, ~p"/pricing")

    assert conn.status == 200
    assert html_response(conn, 200) =~ "Prices follow the resources an app gets"
  end

  # The published table is fully data-driven: every Size row the read
  # returns renders with its own rate labels — expectations computed
  # from a Size read, never literals, so admin price edits never break
  # the suite (and the row count is never hardcoded).
  test "GET /pricing renders every published size row with its rate labels", %{conn: conn} do
    # Two rows, distinct rates and decimals so the sort order and the
    # Decimal rendering are observable in markup.
    PricingFixtures.size!(
      monthly_cents: 701,
      stopped_monthly_cents: 91,
      cpu_cores: Decimal.new("2.5"),
      memory_mb: 2048,
      storage_gb: 25
    )

    PricingFixtures.size!(
      monthly_cents: 233,
      stopped_monthly_cents: 17,
      cpu_cores: Decimal.new("0.5"),
      memory_mb: 512,
      storage_gb: 5
    )

    sizes = published_sizes!()

    conn = get(conn, ~p"/pricing")
    html = html_response(conn, 200)

    for size <- sizes do
      assert html =~ size.slug
      assert html =~ Decimal.to_string(size.cpu_cores)
      assert html =~ "#{size.memory_mb} MB"
      assert html =~ "#{size.storage_gb} GB"
      assert html =~ Pricing.format_monthly_rate(size.monthly_cents)

      assert html =~
               "#{Pricing.format_usd(size.stopped_monthly_cents)}/mo while stopped"
    end

    # The ladder renders cheapest first — the rates' first DOM offsets
    # (the table's copies) are ascending, mirroring the read's sort.
    offsets =
      Enum.map(sizes, &offset(html, Pricing.format_monthly_rate(&1.monthly_cents)))

    assert offsets == Enum.sort(offsets)
  end

  test "GET /pricing renders the add-on rates and the free hostnames line", %{conn: conn} do
    conn = get(conn, ~p"/pricing")
    html = html_response(conn, 200)

    gateway_rate = Pricing.format_usd(AccessGateway.monthly_cents())
    domain_rate = Pricing.format_usd(AccessDomain.monthly_cents())

    assert html =~ "#{gateway_rate}/mo per gateway, billed hourly"
    assert html =~ "#{domain_rate}/mo per verified domain, billed hourly"
    assert html =~ "Hostnames under fluxvale.app, public exposure, DNS, and resolution are free."
  end

  test "GET /pricing states the billing model from the accessors", %{conn: conn} do
    conn = get(conn, ~p"/pricing")
    html = html_response(conn, 200)

    welcome = Pricing.format_usd(Accounts.welcome_grant_cents())

    assert html =~ "New accounts start with #{welcome} in credits."
    assert html =~ "One credit is one US cent"
    assert html =~ "There are no subscriptions"
    assert html =~ "your apps stop running rather than accruing debt"
    assert html =~ "Top up to start them again"
    assert html =~ "negative for 30 days"
    assert html =~ "warnings 7 days and 1 day before"
  end

  test "GET /pricing marks the empty calculator mount point", %{conn: conn} do
    conn = get(conn, ~p"/pricing")

    assert html_response(conn, 200) =~ ~s(id="calculator")
  end

  test "meta: branded title, description, canonical", %{conn: conn} do
    html =
      conn
      |> get(~p"/pricing")
      |> html_response(200)

    assert [_match, title] = Regex.run(~r{<title[^>]*>(.*)</title>}s, html)
    assert title == "Pricing · FluxVale"

    assert html =~
             ~s(name="description" content="Per-instance monthly rates from a published size table, prepaid credits, billed hourly.")

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
end
