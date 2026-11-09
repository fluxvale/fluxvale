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
      locked_note: locked_note,
      floors: Keyword.get(opts, :floors, %{})
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

    # The input addresses the ladder by index: "10" is its 3rd rung
    # since the #576 zero rung joined the ladder at index 0.
    storage = LazyHTML.query(doc, "[data-testid='resource-storage']")
    assert LazyHTML.attribute(storage, "disabled") != []
    assert LazyHTML.attribute(storage, "value") == ["2"]

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

  # #612 S3: the floors — a DB-backed version never offers a rung
  # below its defaults (the 0-GB storage rung hides with the compute
  # rungs under them). Render and decode share offered_values/2, so
  # an index can never name a hidden rung.
  describe "floored ladders (#612 S3)" do
    test "rungs below the floor never render; the ladder re-indexes" do
      doc =
        render_sliders([], nil,
          floors: %{"cpu_cores" => "1", "memory_mb" => "1024", "storage_gb" => "10"}
        )

      # The offered rungs start AT the floors — the hidden ones (0-GB
      # included: a DB entry has nowhere to put its data dir) are gone
      # from the ticks, and the input's top index shrank with them.
      assert tick_values(doc, "resource-cpu-cores") == ~w(1 2 4)
      assert tick_values(doc, "resource-memory-mb") == ~w(1024 2048 4096 8192)
      assert tick_values(doc, "resource-storage-gb") == ~w(10 20 50 100)

      cpu = LazyHTML.query(doc, "[data-testid='resource-cpu']")
      assert LazyHTML.attribute(cpu, "max") == ["2"]

      storage = LazyHTML.query(doc, "[data-testid='resource-storage']")
      assert LazyHTML.attribute(storage, "max") == ["3"]
    end

    test "a floor between rungs floors onto the next rung at or above it" do
      doc = render_sliders([], nil, floors: %{"storage_gb" => "7"})

      assert tick_values(doc, "resource-storage-gb") == ~w(10 20 50 100)
    end

    test "a floor past the top rung keeps the top rung, never an empty ladder" do
      doc = render_sliders([], nil, floors: %{"storage_gb" => "200"})

      assert tick_values(doc, "resource-storage-gb") == ~w(100)
    end

    test "resource_strings/2 decodes indices against the floored ladder" do
      floors = %{"storage_gb" => "10"}

      # Index 0 is the floor rung — the same 0 that named 0 GB on the
      # full ladder can never name it here.
      assert AllocationSliders.resource_strings(%{"storage_gb" => "0"}, floors) == %{
               "storage_gb" => "10"
             }

      assert AllocationSliders.resource_strings(%{"storage_gb" => "3"}, floors) == %{
               "storage_gb" => "100"
             }

      # Past the floored top is nameless, exactly like the full ladder.
      assert AllocationSliders.resource_strings(%{"storage_gb" => "4"}, floors) == %{}
    end

    test "the default decode keeps the full ladders (existing callers unchanged)" do
      assert AllocationSliders.resource_strings(%{"storage_gb" => "0"}) == %{
               "storage_gb" => "0"
             }
    end
  end

  defp tick_values(doc, id) do
    doc
    |> LazyHTML.query("##{id}-ticks [data-value]")
    |> LazyHTML.attribute("data-value")
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
      assert AllocationSliders.floor_rung("storage_gb", Decimal.new(2)) == "5"
      assert AllocationSliders.floor_rung("cpu_cores", Decimal.new("0.2")) == "0.25"
    end

    test "the #576 zero rung floors 0 GB at itself" do
      # A stateless app ships 0 GB storage — an on-ladder value now, so
      # the wizard never silently bills it a 5 GB volume.
      assert AllocationSliders.floor_rung("storage_gb", Decimal.new(0)) == "0"
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
