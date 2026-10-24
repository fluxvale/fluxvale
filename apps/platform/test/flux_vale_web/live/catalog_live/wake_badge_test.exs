defmodule FluxValeWeb.CatalogLive.WakeBadgeTest do
  @moduledoc """
  #232's user-facing slice: the catalog card's derived "wakes in ~Xs"
  — shown once the metric has enough samples, absent otherwise, and
  never leaking platform vocabulary (NoK8sLeaks).

  async: false — the badge needs the module-named PromEx tree started
  under supervision (VM-global).
  """

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.Category
  alias FluxVale.TestSupport.NoK8sLeaks
  alias FluxVale.TestSupport.SessionHelpers

  # Kavita-shaped: five 12s totals interpolate to a median of 10 —
  # 8 + (12-8) * (2.5/5) — so "~10s" is the copy shape the test pins.
  @kavita_wake_seconds 12.0

  setup %{conn: conn} do
    {_user, conn} = SessionHelpers.user_with_session(conn)
    {:ok, conn: conn}
  end

  test "the card shows the derived wake estimate once samples exist", %{conn: conn} do
    start_supervised!(FluxVale.PromEx)

    n = System.unique_integer()

    category =
      Category.create!(%{name: "Media #{n}", slug: "media-#{n}"}, authorize?: false)

    App.create!(
      %{name: "Kavita #{n}", slug: "kavita", tagline: "Reads", category_id: category.id},
      authorize?: false
    )

    for _wake <- 1..5 do
      :telemetry.execute(
        [:flux_vale, :wake, :total],
        %{duration: @kavita_wake_seconds},
        %{app: "kavita"}
      )
    end

    {:ok, view, html} = live(conn, ~p"/apps")

    assert has_element?(view, "[data-testid='wake-estimate-kavita']")
    assert html =~ "Wakes in ~"
    NoK8sLeaks.refute_k8s_terms(html)
  end

  test "no samples, no badge — the card stays quiet", %{conn: conn} do
    start_supervised!(FluxVale.PromEx)

    n = System.unique_integer()

    category =
      Category.create!(%{name: "Tools #{n}", slug: "tools-#{n}"}, authorize?: false)

    App.create!(%{name: "Forgejo #{n}", slug: "forgejo-#{n}", category_id: category.id},
      authorize?: false
    )

    {:ok, view, html} = live(conn, ~p"/apps")

    refute html =~ "Wakes in ~"
    refute has_element?(view, "[data-testid*='wake-estimate']")
  end

  test "a minute-plus median formats minutes-and-seconds, not a raw second count", %{
    conn: conn
  } do
    start_supervised!(FluxVale.PromEx)

    n = System.unique_integer()

    category =
      Category.create!(%{name: "Forge-ish #{n}", slug: "forge-ish-#{n}"}, authorize?: false)

    App.create!(%{name: "Forgejo #{n}", slug: "forgejo", category_id: category.id},
      authorize?: false
    )

    # Five identical 90s wakes interpolate to a median of 75 —
    # 60 + (90-60) * (2.5/5) — so "~1m 15s" is the copy shape.
    for _wake <- 1..5 do
      :telemetry.execute(
        [:flux_vale, :wake, :total],
        %{duration: 90.0},
        %{app: "forgejo"}
      )
    end

    {:ok, view, html} = live(conn, ~p"/apps")

    assert has_element?(view, "[data-testid='wake-estimate-forgejo']")
    assert html =~ "Wakes in ~1m 15s"
  end
end
