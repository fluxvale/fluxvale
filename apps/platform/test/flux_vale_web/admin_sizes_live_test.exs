defmodule FluxValeWeb.AdminSizesLiveTest do
  @moduledoc false

  # The size ladder (#501, sizes as compute classes since #558): the
  # seeded sizes with compute, prices, and the referencing-version
  # count — the freeze state the edit form explains. Everything rolls
  # back per test, so both the empty and populated arms are
  # deterministic.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Identity.User
  alias FluxVale.Pricing.Size
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    admin =
      User.create!(
        "admin-sizes-admin-#{@n}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin)}
  end

  test "an unseeded ladder renders the empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/catalog/sizes")

    assert has_element?(view, "[data-testid='admin-sizes']")
    assert has_element?(view, "p", "No sizes seeded yet.")
    refute has_element?(view, "#admin-size-ladder")
  end

  test "the ladder lists compute classes with compute, rates, and referencing-version counts", %{
    conn: conn
  } do
    # One referenced size (the fixture fabricates its version's match)
    # and one free size.
    _version = InstanceFixtures.app_version!()
    loaded = InstanceFixtures.app_version!()
    referenced_size = Ash.load!(loaded, [:recommended_size]).recommended_size

    free = size!(%{slug: "ladder-free-#{@n}"})

    {:ok, view, _html} = live(conn, "/admin/catalog/sizes")

    # Rows are keyed by slug; the compute is the one shared formatter
    # (the fixture's defaults are 0.5 CPU, 256 MB, middle dots) — and
    # no GB term: a compute class prices no storage (#558).
    assert has_element?(
             view,
             "#size-row-#{referenced_size.slug}",
             "0.5 CPU · 256 MB"
           )

    refute has_element?(view, "#size-row-#{referenced_size.slug}", "GB")

    assert has_element?(view, "#size-row-#{free.slug}")

    # The freeze state as a count: referenced sizes badge it, a free
    # row reads a plain zero.
    assert has_element?(
             view,
             "[data-testid='admin-size-versions-#{referenced_size.slug}']",
             "1 version"
           )

    assert has_element?(view, "[data-testid='admin-size-versions-#{free.slug}']", "0")

    # Rates render in the product's one-string idiom, from the one
    # dollars formatter, never literals. A compute class has no
    # stopped rate — stopped pays storage per GB on its own axis — so
    # no stopped column at all.
    rate = "#{FluxVale.Pricing.format_usd(referenced_size.monthly_cents)}/mo"
    assert has_element?(view, "#size-row-#{referenced_size.slug}", rate)
    refute has_element?(view, "#admin-size-ladder th", "Stopped rate")

    # Each row hands off to its edit form.
    assert has_element?(
             view,
             "[data-testid='admin-size-edit-#{free.slug}'][href='/admin/catalog/sizes/#{free.id}']"
           )

    # And the catalog list is one hop back.
    assert has_element?(
             view,
             "[data-testid='admin-catalog-link'][href='/admin/catalog']"
           )
  end

  # Local: PricingFixtures.size! still passes #558-removed keys, so the
  # ladder's rows go through the create action directly.
  defp size!(overrides) do
    n = System.unique_integer()

    %{
      slug: "size-#{n}",
      cpu_cores: Decimal.new("1"),
      memory_mb: 1024,
      monthly_cents: 500
    }
    |> Map.merge(Map.new(overrides))
    |> Size.create!(authorize?: false)
  end
end
