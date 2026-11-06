defmodule FluxValeWeb.AllocationSlidersTest do
  @moduledoc false

  # The shared block's `locked` dimension (#493): the resize panel locks
  # storage behind the cluster's expansion capability — a locked rung
  # renders disabled, the note renders once, and default call sites
  # (deploy stepper, calculator) stay byte-identical: no disabled attr,
  # no note.

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias FluxValeWeb.AllocationSliders

  @rungs %{"cpu_cores" => "0.5", "memory_mb" => "512", "storage_gb" => "10"}

  defp render_sliders(locked, locked_note) do
    assigns = %{resources: @rungs, name: "resize", locked: locked, locked_note: locked_note}
    html = render_component(&AllocationSliders.sliders/1, assigns)

    LazyHTML.from_fragment(html)
  end

  defp disabled?(doc, testid) do
    input = LazyHTML.query(doc, "[data-testid='#{testid}']")
    LazyHTML.attribute(input, "disabled") != []
  end

  test "a locked dimension renders its input disabled at its rung, with the note" do
    doc = render_sliders(["storage_gb"], "Storage can't be expanded on this cluster yet.")

    # The input addresses the ladder by index: "10" is its 2nd rung.
    storage = LazyHTML.query(doc, "[data-testid='resource-storage']")
    assert LazyHTML.attribute(storage, "disabled") != []
    assert LazyHTML.attribute(storage, "value") == ["1"]

    refute disabled?(doc, "resource-cpu")
    refute disabled?(doc, "resource-memory")

    locked_note_query = LazyHTML.query(doc, "[data-testid='slider-locked-note']")
    notes = LazyHTML.attribute(locked_note_query, "data-testid")

    assert notes == ["slider-locked-note"]
    assert LazyHTML.text(doc) =~ "Storage can't be expanded on this cluster yet."
  end

  test "a default call renders every input enabled and no note" do
    doc = render_sliders([], nil)

    refute disabled?(doc, "resource-cpu")
    refute disabled?(doc, "resource-memory")
    refute disabled?(doc, "resource-storage")

    locked_note_query = LazyHTML.query(doc, "[data-testid='slider-locked-note']")
    notes = LazyHTML.attribute(locked_note_query, "data-testid")

    assert notes == []
  end
end
