defmodule FluxValeWeb.AllocationSliders do
  @moduledoc """
  The allocation rung sliders (#394): the deploy wizard's resources
  step and the /pricing calculator (#397) render the same control, so
  playing with allocations feels identical everywhere. The ladders,
  the slider markup, and the index decode live here — extracted from
  `CatalogLive.Deploy` verbatim, zero behavior change.

  Storage renders as its own control (#558): the compute sliders (CPU,
  memory — the size rungs) group under a Compute label, storage stands
  in its own labeled section with its per-GB pricing note. The wire
  shape is unchanged — a storage slider still emits `resources[KEY]`
  like the compute sliders, so consumers keep decoding one payload.

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

  The rung math lives here too (#493): `nearest_rung/2` and
  `floor_rung/2` are the shared seeding helpers, numeric end to end.
  """

  use FluxValeWeb, :html

  # The sliders' rungs (#221): the compute ladders are the seeded Size
  # rows' distinct values for those dimensions (micro…pro — the same
  # business data the quick picks and pricing carry; the #233 top
  # rungs were rejected on #399, the arrays stop at pro), ascending,
  # and a test pins the arrays to the seeds. Storage is its own axis
  # (#558): the ladder is the offered per-GB range, not a size
  # property. The sliders
  # address rungs by index (a range input can only step uniformly),
  # so the LiveView — not the browser — owns the value arrays. Values
  # outside the ladder stay legal at the API (the Instance attribute
  # constraints, unchanged); this step just never offers them.
  @doc """
  The compute ladders (CPU, memory) and the storage ladder, ascending —
  the only allocations the sliders can express. The wizard floors
  version defaults onto them and filters its quick picks against the
  compute rungs.
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
  The storage dimension's own section (#558): renders under its own
  Storage label with the per-GB pricing note, separated from the
  compute sliders. `hidden` or `locked` storage keeps the note only
  when the slider itself renders.
  """
  @spec storage_dimension() :: map()
  def storage_dimension do
    Enum.find(resource_dimensions(), &(&1.key == "storage_gb")) ||
      raise(ArgumentError, "storage dimension missing from resource_dimensions/0")
  end

  @doc """
  The rung numerically closest to `value`; a tie takes the cheaper
  rung (the ladders ascend, and the first minimum wins). Numeric
  distance end to end: Decimal structs don't order numerically under
  term comparison, so the absolute distance converts to a float for
  the sort key only — the rung itself stays a string.
  """
  @spec nearest_rung(String.t(), Decimal.t() | number() | binary()) :: String.t()
  def nearest_rung(dimension_key, value) do
    dimension = dimension!(dimension_key)
    target = decimal(value)
    rungs = dimension.values

    Enum.min_by(rungs, fn rung ->
      rung
      |> decimal()
      |> Decimal.sub(target)
      |> Decimal.abs()
      |> Decimal.to_float()
    end)
  end

  @doc """
  The smallest rung at or above `value` — a value past the top rung
  floors to the top rung (the ladder never offers more).
  """
  @spec floor_rung(String.t(), Decimal.t() | number() | binary()) :: String.t()
  def floor_rung(dimension_key, value) do
    dimension = dimension!(dimension_key)
    target = decimal(value)

    at_or_above? = fn rung ->
      rung_decimal = decimal(rung)
      Decimal.compare(rung_decimal, target) != :lt
    end

    dimension.values
    |> Enum.find(at_or_above?)
    |> Kernel.||(List.last(dimension.values))
  end

  # One lookup with an honest failure: a typo'd key is a caller bug,
  # not a silent nil rung.
  defp dimension!(dimension_key) do
    Enum.find(resource_dimensions(), &(&1.key == dimension_key)) ||
      raise(ArgumentError, "unknown allocation dimension: #{dimension_key}")
  end

  defp decimal(value) when is_binary(value), do: Decimal.new(value)
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(%Decimal{} = value), do: value

  @doc """
  The three sliders as one block — the wizard's Fine-tune markup,
  byte-identical. The change event rides the form that embeds the
  block; `name` is the params namespace the inputs emit under. A
  dimension in `locked` renders disabled: the browser omits a disabled
  input from the form payload, so the caller's server-side merge
  carries the seeded rung (or the caller omits the dimension from what
  it applies — the action's absent = keep-the-row semantics).
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

  attr(:hidden, :list,
    default: [],
    doc:
      "dimension keys not rendered at all — display-only (the wire omission is the caller's server-side decision); for a row whose locked value isn't a rung, a nearest-rung slider would read as an imminent shrink"
  )

  attr(:locked_note, :string,
    default: nil,
    doc: "one plain line under the block when a dimension is locked"
  )

  @spec sliders(map()) :: Phoenix.LiveView.Rendered.t()
  def sliders(assigns) do
    ~H"""
    <div class="space-y-4 border-t border-line pt-5" data-testid="allocation-sliders">
      <p class="text-sm font-medium text-ink">Fine-tune</p>
      <div
        :if={compute_group?(@hidden)}
        class="space-y-4"
        aria-label="Compute"
        data-testid="allocation-compute-group"
      >
        <p class="text-xs font-medium uppercase tracking-wide text-ink-subtle">Compute</p>
        <.slider
          :for={dimension <- compute_dimensions(@hidden)}
          id={dimension.id}
          name={"#{@name}[#{dimension.key}]"}
          label={dimension.label}
          value={@resources[dimension.key]}
          values={dimension.values}
          unit={dimension.unit}
          disabled={dimension.key in @locked}
          data-testid={dimension.testid}
        />
      </div>
      <div
        :if={storage_offered?(@hidden)}
        class="space-y-2 rounded-xl border border-line bg-panel px-4 py-4"
        aria-label="Storage"
        data-testid="allocation-storage-group"
      >
        <p class="text-xs font-medium uppercase tracking-wide text-ink-subtle">Storage</p>
        <.slider
          id={storage_dimension().id}
          name={"#{@name}[#{storage_dimension().key}]"}
          label={storage_dimension().label}
          value={@resources[storage_dimension().key]}
          values={storage_dimension().values}
          unit={storage_dimension().unit}
          disabled={storage_dimension().key in @locked}
          data-testid={storage_dimension().testid}
        />
        <p class="text-xs text-ink-subtle" data-testid="storage-per-gb-note">
          {gettext("Priced per GB of storage, including while the instance is stopped.")}
        </p>
      </div>
      <p :if={@locked_note} class="text-xs text-ink-subtle" data-testid="slider-locked-note">
        {@locked_note}
      </p>
    </div>
    """
  end

  # The compute group renders whenever any compute slider renders; a
  # caller hiding both compute dimensions (nobody does today) would
  # see the group heading go with them.
  defp compute_dimensions(hidden) do
    Enum.reject(resource_dimensions(), &(&1.key == "storage_gb" or &1.key in hidden))
  end

  defp compute_group?(hidden), do: compute_dimensions(hidden) != []

  defp storage_offered?(hidden), do: "storage_gb" not in hidden

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
