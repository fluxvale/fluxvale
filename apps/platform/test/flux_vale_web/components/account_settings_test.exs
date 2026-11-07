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

    # The one net-new user-visible copy in this PR, pinned verbatim
    # (plain words: no punctuation tricks to drift into the labels).
    for {key, label} <- [{"account", "Account"}, {"billing", "Billing"}] do
      label_text =
        doc
        |> LazyHTML.query("[data-testid='account-settings-section-#{key}'] p")
        |> LazyHTML.text()
        |> String.trim()

      assert label_text == label

      section =
        doc
        |> LazyHTML.query("[data-testid='account-settings-section-#{key}']")
        |> Enum.to_list()

      assert section != [], "the #{key} section should render"
    end

    aria =
      doc
      |> LazyHTML.query("[data-testid='account-settings-sidebar']")
      |> LazyHTML.attribute("aria-label")
      |> List.first()

    assert aria == "Account settings"
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

  test "no personal org: the gated sections never ship (no dead entries)" do
    html = render_component(&AccountSettings.sidebar/1, current: "profile")

    assert links(html) == [{"Profile", "/settings", true}]

    doc = LazyHTML.from_fragment(html)

    for key <- ["access", "billing"] do
      assert doc
             |> LazyHTML.query("[data-testid='account-settings-section-#{key}']")
             |> Enum.to_list() == []
    end
  end
end
