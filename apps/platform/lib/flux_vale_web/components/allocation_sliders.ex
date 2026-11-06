defmodule FluxValeWeb.AllocationSliders do
  @moduledoc """
  The three allocation rung sliders (#394): the deploy wizard's
  resources step and the /pricing calculator (#397) render the same
  control, so playing with allocations feels identical everywhere. The
  ladders, the slider markup, and the index decode live here —
  extracted from `CatalogLive.Deploy` verbatim, zero behavior change.

  Events belong to the form that embeds the block: the wizard's
  `resources-form` keeps its `phx-change` / `phx-submit`, unchanged.
  On the wire each slider emits `resources[KEY]` holding its rung's
  index, and `resource_strings/1` decodes a payload back to rungs — a
  crafted index that names no rung is silence.

  The DOM ids and testids (`resource-cpu-cores`, `resource-memory-mb`,
  `resource-storage-gb`, `resource-cpu`/`-memory`/`-storage`) are
  page-unique by contract — a consumer embedding this block twice on
  the same page must parameterize them first (the wizard and the
  /pricing calculator are separate pages, so they stay unique today).
  """

  use FluxValeWeb, :html

  # The sliders' rungs (#221): each dimension's ladder is the seeded
  # Size rows' distinct values for it (micro…pro — the same business
  # data the quick picks and pricing carry; the #233 top rungs were
  # rejected on #399, the arrays stop at pro), ascending; a test pins
  # the arrays to the seeds. The sliders
  # address rungs by index (a range input can only step uniformly),
  # so the LiveView — not the browser — owns the value arrays. Values
  # outside the ladder stay legal at the API (the Instance attribute
  # constraints, unchanged); this step just never offers them.
  @doc """
  The CPU, memory, and storage ladders, ascending — the only
  allocations the sliders can express. The wizard floors version
  defaults onto them and filters its quick picks against them.
  """
  @spec resource_dimensions() :: [map()]
  def resource_dimensions do
    [
      %{
        key: "cpu_cores",
        id: "resource-cpu-cores",
        label: "CPU cores",
        testid: "resource-cpu",
        values: ["0.25", "0.5", "1", "2", "4"],
        unit: "cores"
      },
      %{
        key: "memory_mb",
        id: "resource-memory-mb",
        label: "Memory",
        testid: "resource-memory",
        values: ["512", "1024", "2048", "4096", "8192"],
        unit: "MB"
      },
      %{
        key: "storage_gb",
        id: "resource-storage-gb",
        label: "Storage",
        testid: "resource-storage",
        values: ["5", "10", "20", "50", "100"],
        unit: "GB"
      }
    ]
  end

  @doc """
  The three sliders as one block — the wizard's Fine-tune markup,
  byte-identical. The change event rides the form that embeds the
  block; `name` is the params namespace the inputs emit under. A
  dimension in `locked` renders disabled (its rung rides the form
  regardless — a caller may keep the row's value by dropping that key);
  `locked_note` renders once under the block.
  """
  attr(:resources, :map,
    required: true,
    doc: "the current rung state, each dimension key pointing at its rung string"
  )

  attr(:name, :string,
    default: "resources",
    doc: "the params namespace the sliders emit under — resources[KEY] on the wire"
  )

  attr(:locked, :list,
    default: [],
    doc: "dimension keys rendered disabled at their current rung"
  )

  attr(:locked_note, :string,
    default: nil,
    doc: "one plain line under the block when a dimension is locked"
  )

  @spec sliders(map()) :: Phoenix.LiveView.Rendered.t()
  def sliders(assigns) do
    ~H"""
    <div class="space-y-4 border-t border-line pt-5">
      <p class="text-sm font-medium text-ink">Fine-tune</p>
      <.slider
        :for={dimension <- resource_dimensions()}
        id={dimension.id}
        name={"#{@name}[#{dimension.key}]"}
        label={dimension.label}
        value={@resources[dimension.key]}
        values={dimension.values}
        unit={dimension.unit}
        disabled={dimension.key in @locked}
        data-testid={dimension.testid}
      />
      <p :if={@locked_note} class="text-xs text-ink-subtle" data-testid="slider-locked-note">
        {@locked_note}
      </p>
    </div>
    """
  end

  # The sliders' wire format (#221): indices into the dimension's
  # rungs, translated here — only a well-formed index of the
  # dimension's own ladder becomes state, and every other index VALUE
  # (a crafted event: out of range, negative, fractional, non-numeric,
  # a non-string) is silence, exactly like an unknown preset slug. A
  # non-map `resources` payload is a malformed event like any other
  # unmatched shape (save without "instance" — main's posture). Absent
  # keys carry no opinion (a browser sends every input; LiveViewTest
  # sends the ones under test), so the caller merges over the current
  # state.
  @doc """
  A change payload's slider indices decoded to rungs. Absent keys
  carry no opinion and a crafted index that names no rung is dropped,
  so the caller merges the result over its current state.
  """
  @spec resource_strings(map()) :: map()
  def resource_strings(params) do
    resource_dimensions()
    |> Map.new(fn dimension ->
      {dimension.key, rung_at(dimension, Map.get(params, dimension.key))}
    end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp rung_at(_dimension, index) when not is_binary(index), do: nil

  defp rung_at(dimension, index) do
    case Integer.parse(index) do
      {i, ""} when i >= 0 -> Enum.at(dimension.values, i)
      _crafted_or_malformed -> nil
    end
  end
end
