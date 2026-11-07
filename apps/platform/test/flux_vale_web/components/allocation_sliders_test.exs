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

  defp render_sliders(locked, locked_note, opts \\ []) do
    assigns = %{
      resources: @rungs,
      name: "resize",
      locked: locked,
      hidden: Keyword.get(opts, :hidden, []),
      locked_note: locked_note
    }

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

    # The locked state must READ locked (F4, the vision pass — a
    # disabled slider otherwise renders identical to enabled): muted
    # thumb + track, refused cursor.
    [storage_class] = LazyHTML.attribute(storage, "class")
    assert storage_class =~ "cursor-not-allowed"
    assert storage_class =~ "opacity-45"
    assert storage_class =~ "bg-ink-subtle"

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

    # The enabled styling hook, for contrast with the locked one.
    cpu = LazyHTML.query(doc, "[data-testid='resource-cpu']")
    [cpu_class] = LazyHTML.attribute(cpu, "class")
    assert cpu_class =~ "cursor-pointer"
    refute cpu_class =~ "opacity-45"

    locked_note_query = LazyHTML.query(doc, "[data-testid='slider-locked-note']")
    notes = LazyHTML.attribute(locked_note_query, "data-testid")

    assert notes == []
  end

  test "a hidden dimension renders neither input nor ticks" do
    doc = render_sliders(["storage_gb"], nil, hidden: ["storage_gb"])

    input = LazyHTML.query(doc, "[data-testid='resource-storage']")
    assert LazyHTML.attribute(input, "data-testid") == []

    ticks = LazyHTML.query(doc, "#resource-storage-gb-ticks")
    assert LazyHTML.attribute(ticks, "id") == []

    # The other dimensions render untouched.
    refute disabled?(doc, "resource-cpu")
  end

  # #558: storage renders as its own control — its own labeled section,
  # separate from the compute sliders, with the per-GB pricing note.
  test "storage renders in its own section with the per-GB note, compute grouped apart" do
    doc = render_sliders([], nil)

    storage_group = LazyHTML.query(doc, "[data-testid='allocation-storage-group']")
    assert LazyHTML.attribute(storage_group, "aria-label") == ["Storage"]
    assert LazyHTML.text(storage_group) =~ "Priced per GB of storage"

    compute_group = LazyHTML.query(doc, "[data-testid='allocation-compute-group']")
    assert LazyHTML.attribute(compute_group, "aria-label") == ["Compute"]
    # The compute group holds CPU and memory only — storage is not a
    # size rung anymore.
    cpu_in_compute = LazyHTML.query(compute_group, "[data-testid='resource-cpu']")
    assert LazyHTML.attribute(cpu_in_compute, "data-testid") == ["resource-cpu"]

    memory_in_compute = LazyHTML.query(compute_group, "[data-testid='resource-memory']")
    assert LazyHTML.attribute(memory_in_compute, "data-testid") == ["resource-memory"]

    storage_in_compute = LazyHTML.query(compute_group, "[data-testid='resource-storage']")
    assert LazyHTML.attribute(storage_in_compute, "data-testid") == []
  end

  test "a hidden storage dimension drops its whole section, compute stays" do
    doc = render_sliders([], nil, hidden: ["storage_gb"])

    storage_group = LazyHTML.query(doc, "[data-testid='allocation-storage-group']")
    assert LazyHTML.attribute(storage_group, "data-testid") == []

    compute_group = LazyHTML.query(doc, "[data-testid='allocation-compute-group']")
    assert LazyHTML.attribute(compute_group, "aria-label") == ["Compute"]
  end

  test "a locked slider's active tick reads muted (the enabled one reads primary)" do
    locked_doc = render_sliders(["storage_gb"], nil, [])

    # The storage rung's active tick sits under the muted thumb: the
    # active dot is line-strong, never primary.
    active_tick =
      locked_doc
      |> LazyHTML.query("[data-value='10'] span")
      |> LazyHTML.attribute("class")
      |> List.first()

    assert active_tick =~ "bg-line-strong"
    refute active_tick =~ "bg-primary"

    enabled_doc = render_sliders([], nil, [])

    active_enabled =
      enabled_doc
      |> LazyHTML.query("[data-value='10'] span")
      |> LazyHTML.attribute("class")
      |> List.first()

    assert active_enabled =~ "bg-primary"
  end

  # The rung seeding math (F2) is numeric end to end — the regression
  # being min_by over Decimal STRUCTS (term order), which seeded 0.2 at
  # 0.5 instead of 0.25.

  describe "nearest_rung/2" do
    test "a sub-rung value seeds DOWN to the nearest rung" do
      assert AllocationSliders.nearest_rung("cpu_cores", Decimal.new("0.2")) == "0.25"
    end

    test "a mid-gap value seeds at its numerically closest rung" do
      assert AllocationSliders.nearest_rung("memory_mb", Decimal.new(700)) == "512"
      assert AllocationSliders.nearest_rung("memory_mb", "700") == "512"
      assert AllocationSliders.nearest_rung("storage_gb", 12) == "10"
    end

    test "an exact rung seeds at itself" do
      assert AllocationSliders.nearest_rung("cpu_cores", "0.5") == "0.5"
      assert AllocationSliders.nearest_rung("storage_gb", Decimal.new(10)) == "10"
    end

    test "a distance tie takes the cheaper rung" do
      # 15 sits equidistant between 10 and 20 — the ladder ascends, so
      # the first minimum (the cheaper rung) wins.
      assert AllocationSliders.nearest_rung("storage_gb", Decimal.new(15)) == "10"
    end

    test "an unknown dimension is a caller bug, raised" do
      assert_raise(ArgumentError, ~r/unknown allocation dimension/, fn ->
        AllocationSliders.nearest_rung("gpu", Decimal.new(1))
      end)
    end
  end

  describe "floor_rung/2" do
    test "the smallest rung at or above the value wins" do
      assert AllocationSliders.floor_rung("storage_gb", Decimal.new(7)) == "10"
      assert AllocationSliders.floor_rung("storage_gb", Decimal.new(0)) == "5"
      assert AllocationSliders.floor_rung("cpu_cores", Decimal.new("0.2")) == "0.25"
    end

    test "a value past the top rung floors to the top rung" do
      assert AllocationSliders.floor_rung("storage_gb", Decimal.new(200)) == "100"
      assert AllocationSliders.floor_rung("memory_mb", Decimal.new(16_384)) == "8192"
    end

    test "an exact rung floors at itself" do
      assert AllocationSliders.floor_rung("storage_gb", Decimal.new(10)) == "10"
    end
  end
end
