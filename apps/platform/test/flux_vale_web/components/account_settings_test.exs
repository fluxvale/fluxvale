defmodule FluxValeWeb.Components.AccountSettingsTest do
  @moduledoc """
  The account settings sidebar's contract (#551): one entry per surface,
  grouped Account (Profile, Access, Developer) and Billing (Wallet), the
  active entry aria-current. The Access entry rides the personal-org
  gate — no dead entries ship. Developer (#635) is ungated: the page
  needs no org.
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
             {"Developer", "/settings/developer", false},
             {"Wallet", "/billing", false}
           ]

    doc = LazyHTML.from_fragment(html)

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
             {"Developer", "/settings/developer", false},
             {"Wallet", "/billing", false}
           ]

    developer_page =
      render_component(&AccountSettings.sidebar/1, current: "developer", personal_org_id: "org_1")

    assert links(developer_page) == [
             {"Profile", "/settings", false},
             {"Access", "/settings/access", false},
             {"Developer", "/settings/developer", true},
             {"Wallet", "/billing", false}
           ]
  end

  test "no personal org: the gated sections never ship (no dead entries)" do
    html = render_component(&AccountSettings.sidebar/1, current: "profile")

    # Developer stays beside Profile — its page is actor-scoped (#635),
    # so the entry is no dead end for the no-org actor.
    assert links(html) == [
             {"Profile", "/settings", true},
             {"Developer", "/settings/developer", false}
           ]

    doc = LazyHTML.from_fragment(html)

    for key <- ["access", "billing"] do
      assert doc
             |> LazyHTML.query("[data-testid='account-settings-section-#{key}']")
             |> Enum.to_list() == []
    end
  end
end
