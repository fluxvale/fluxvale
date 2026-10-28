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
    test "info and error toasts: boxes opt out, close button opts in" do
      for kind <- [:info, :error] do
        doc = render_flash(kind)
        id = "flash-#{kind}"

        # The wide fixed box that used to eat header/menu clicks, and the
        # visible card — the card used to re-enable pointer events. A
        # phx-click on either would still swallow clicks landing there.
        container = LazyHTML.query(doc, "##{id}")
        card = LazyHTML.query(doc, "##{id} > div")
        [container_class] = LazyHTML.attribute(container, "class")
        [card_class] = LazyHTML.attribute(card, "class")

        assert container_class =~ "pointer-events-none"
        assert card_class =~ "pointer-events-none"
        refute container_class =~ "pointer-events-auto"
        refute card_class =~ "pointer-events-auto"
        assert [] == LazyHTML.attribute(container, "phx-click")

        # The close button is the one element that opts back in, and the
        # dismiss handler clears exactly its kind and hides its own toast.
        # No aria-label selector: gettext may translate it.
        button = LazyHTML.query(doc, "##{id} > div > button")
        [button_class] = LazyHTML.attribute(button, "class")

        assert button_class =~ "pointer-events-auto"

        [dismiss] = LazyHTML.attribute(button, "phx-click")
        assert dismiss =~ "lv:clear-flash"
        assert dismiss =~ ~s("key":"#{kind}")
        assert dismiss =~ "##{id}"
      end
    end

    test "caller attrs still ride the container: rest, custom id, hidden" do
      assigns = %{
        :"phx-mounted" => "transition-in",
        id: "welcome-back",
        kind: :info,
        flash: %{"info" => "Welcome Back!"},
        hidden: true
      }

      html = render_component(&CoreComponents.flash/1, assigns)
      doc = LazyHTML.from_fragment(html)

      container = LazyHTML.query(doc, "#welcome-back")

      assert ["transition-in"] == LazyHTML.attribute(container, "phx-mounted")
      # hidden renders valueless — pin presence, not serialization.
      assert [_present] = LazyHTML.attribute(container, "hidden")

      # The hide target follows the caller's id, not the default one.
      button = LazyHTML.query(doc, "#welcome-back > div > button")
      [dismiss] = LazyHTML.attribute(button, "phx-click")
      assert dismiss =~ "#welcome-back"
    end
  end
end
