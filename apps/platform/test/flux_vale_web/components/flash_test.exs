defmodule FluxValeWeb.Components.FlashTest do
  @moduledoc false

  # #294: the z-50 toast box covered the whole header at 375px and the
  # account menu at every width until dismissed. Which element a click
  # lands on when boxes overlap is browser hit-testing — no layout
  # engine runs under ExUnit — so this pins the class wiring that
  # produces it: both toast boxes pass pointer events through to the
  # page beneath, and the close button is the one element that opts
  # back in (and the only home of the dismiss handler).

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias FluxValeWeb.CoreComponents

  defp render_flash(kind) do
    # Flash maps from the conn/LiveView carry string keys.
    assigns = %{flash: %{Atom.to_string(kind) => "Signed in."}, kind: kind}
    html = render_component(&CoreComponents.flash/1, assigns)

    LazyHTML.from_fragment(html)
  end

  describe "flash/1 passes clicks through to the page beneath (#294)" do
    test "info toast: container and card opt out, close button opts in" do
      doc = render_flash(:info)

      # The wide fixed box that used to eat header/menu clicks.
      container = LazyHTML.query(doc, "#flash-info")

      assert LazyHTML.attribute(container, "class") ==
               ["pointer-events-none fixed top-4 right-4 z-50 w-[calc(100%-2rem)] max-w-sm"]

      # Pass-through boxes must not carry the dismiss handler — a
      # phx-click there would still swallow clicks that land on them.
      assert LazyHTML.attribute(container, "phx-click") == []

      card = LazyHTML.query(doc, "#flash-info > div")

      assert LazyHTML.attribute(card, "class") == [
               "pointer-events-none flex items-start gap-3 rounded-xl border bg-panel p-4 shadow-lg border-line text-ink"
             ]

      button = LazyHTML.query(doc, ~s(#flash-info button[aria-label="close"]))

      assert LazyHTML.attribute(button, "class") ==
               ["group -m-1 cursor-pointer p-1 pointer-events-auto"]

      [dismiss] = LazyHTML.attribute(button, "phx-click")
      assert dismiss =~ "lv:clear-flash"
      assert dismiss =~ "#flash-info"
    end

    test "error toast: same pass-through wiring" do
      doc = render_flash(:error)

      container = LazyHTML.query(doc, "#flash-error")

      assert ["pointer-events-none fixed top-4 right-4 z-50 w-[calc(100%-2rem)] max-w-sm"] ==
               LazyHTML.attribute(container, "class")

      assert [] == LazyHTML.attribute(container, "phx-click")

      card = LazyHTML.query(doc, "#flash-error > div")

      assert [
               "pointer-events-none flex items-start gap-3 rounded-xl border bg-panel p-4 shadow-lg border-line-danger text-ink"
             ] == LazyHTML.attribute(card, "class")

      button = LazyHTML.query(doc, ~s(#flash-error button[aria-label="close"]))

      assert ["group -m-1 cursor-pointer p-1 pointer-events-auto"] ==
               LazyHTML.attribute(button, "class")

      [dismiss] = LazyHTML.attribute(button, "phx-click")
      assert dismiss =~ "lv:clear-flash"
      assert dismiss =~ "#flash-error"
    end
  end
end
