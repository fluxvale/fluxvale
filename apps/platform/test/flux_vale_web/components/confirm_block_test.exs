defmodule FluxValeWeb.Components.ConfirmBlockTest do
  @moduledoc false

  # #532: the destructive confirm's contract after the a11y hardening —
  # the AA danger ink on the danger-muted fill, the announcement and
  # focus handoff, and the destructive button's token focus ring.

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias FluxValeWeb.CoreComponents

  @attrs %{
    title: "Stop backing this app up?",
    body: "This app stops backing up and the schedule is removed.",
    note: "Keep your backup password.",
    action: "Yes, stop backing up",
    event: "remove-settings",
    action_testid: "test-confirm",
    cancel_testid: "test-cancel",
    cancel_event: "cancel-confirm",
    return_focus: "[data-testid='test-trigger']",
    myself: nil
  }

  defp render(attrs \\ %{}) do
    assigns = Map.merge(@attrs, attrs)
    html = render_component(&CoreComponents.confirm_block/1, assigns)
    LazyHTML.from_fragment(html)
  end

  describe "confirm_block/1" do
    test "announces itself and carries the focus handoff" do
      doc = render()
      block = LazyHTML.query(doc, "[data-testid=destructive-confirm]")

      assert LazyHTML.attribute(block, "role") == ["alert"]
      assert LazyHTML.attribute(block, "tabindex") == ["-1"]

      assert LazyHTML.attribute(block, "phx-hook") == [
               "FluxValeWeb.CoreComponents.ConfirmFocus"
             ]

      assert LazyHTML.attribute(block, "data-return-focus") == ["[data-testid='test-trigger']"]
      assert LazyHTML.attribute(block, "id") == ["test-confirm-block"]
    end

    test "the heading uses the AA danger ink, never the base danger ink" do
      heading = LazyHTML.query(render(), "p.text-danger-deep")
      [heading_class] = LazyHTML.attribute(heading, "class")

      assert heading_class =~ "text-danger-deep"
      refute heading_class =~ ~r/(^|\s)text-danger(\s|$)/
    end

    test "the buttons are named and carry the shared focus ring" do
      doc = render()
      action = LazyHTML.query(doc, "button[data-testid=test-confirm]")
      [action_class] = LazyHTML.attribute(action, "class")
      action_text = LazyHTML.text(action)

      assert String.trim(action_text) == "Yes, stop backing up"
      assert action_class =~ "focus-visible:outline-2"
      assert action_class =~ "outline-focus"
      assert action_class =~ "text-danger-deep"

      cancel = LazyHTML.query(doc, "button[data-testid=test-cancel]")
      [cancel_class] = LazyHTML.attribute(cancel, "class")
      cancel_text = LazyHTML.text(cancel)

      assert String.trim(cancel_text) == "Cancel"
      assert cancel_class =~ "focus-visible:outline-2"
      assert cancel_class =~ "outline-focus"
    end

    test "without a return target the attribute is omitted" do
      doc = render(%{return_focus: nil})
      block = LazyHTML.query(doc, "[data-testid=destructive-confirm]")

      assert LazyHTML.attribute(block, "data-return-focus") == []
    end
  end

  describe "status_badge/1 danger states" do
    test "use the AA danger ink on the danger-muted fill" do
      for status <- [:error, :deleting, :lost, :destroying] do
        html = render_component(&CoreComponents.status_badge/1, %{status: status})
        doc = LazyHTML.from_fragment(html)
        [class] = LazyHTML.attribute(doc, "class")

        assert class =~ "bg-danger-muted"
        assert class =~ "text-danger-deep"
        refute class =~ ~r/(^|\s)text-danger(\s|$)/
      end
    end
  end
end
