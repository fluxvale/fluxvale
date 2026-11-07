defmodule FluxValeWeb.Components.AccountSettingsTest do
  @moduledoc """
  The account settings sidebar's contract (#551): one entry per surface,
  grouped Account (Profile, Access) and Billing (Wallet), the active
  entry aria-current. The Access entry rides the personal-org gate —
  no dead entries ship.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias FluxValeWeb.AccountSettings

  # The sidebar's entries, in document order: label, href, active mark.
  defp links(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-testid='account-settings-sidebar'] a")
    |> Enum.map(fn link ->
      href =
        link
        |> LazyHTML.attribute("href")
        |> List.first()

      active = LazyHTML.attribute(link, "aria-current") == ["page"]

      label =
        link
        |> LazyHTML.text()
        |> String.trim()

      {label, href, active}
    end)
  end

  test "sections Account and Billing, one entry per surface at its own path" do
    html =
      render_component(&AccountSettings.sidebar/1, current: "profile", personal_org_id: "org_1")

    assert links(html) == [
             {"Profile", "/settings", true},
             {"Access", "/settings/access", false},
             {"Wallet", "/billing", false}
           ]

    doc = LazyHTML.from_fragment(html)

    for key <- ["account", "billing"] do
      section =
        doc
        |> LazyHTML.query("[data-testid='account-settings-section-#{key}']")
        |> Enum.to_list()

      assert section != [], "the #{key} section label should render"
    end
  end

  test "the active entry flips with the surface" do
    html =
      render_component(&AccountSettings.sidebar/1, current: "access", personal_org_id: "org_1")

    assert links(html) == [
             {"Profile", "/settings", false},
             {"Access", "/settings/access", true},
             {"Wallet", "/billing", false}
           ]
  end

  test "no personal org: the Access entry never ships (no dead entries)" do
    html = render_component(&AccountSettings.sidebar/1, current: "profile")

    assert links(html) == [
             {"Profile", "/settings", true},
             {"Wallet", "/billing", false}
           ]
  end
end
