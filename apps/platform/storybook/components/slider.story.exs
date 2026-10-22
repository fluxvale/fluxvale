defmodule FluxValeWeb.Storybook.Components.Slider do
  @moduledoc """
  Slider stories — the selectable continuous control (#195).
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.slider/1
  def render_source, do: :function
  def layout, do: :one_column

  def template do
    """
    <div class="max-w-md space-y-4"><.psb-variation/></div>
    """
  end

  def variations do
    [
      %VariationGroup{
        id: :allocation,
        description: "The deploy wizard's three dimensions (#195)",
        variations: [
          %Variation{
            id: :cpu,
            description: "CPU — 0.25-core snap, 64-core ceiling",
            attributes: %{
              id: "cpu",
              name: "resources[cpu_cores]",
              label: "CPU cores",
              value: "0.5",
              min: "0.25",
              max: "64",
              step: "0.25",
              unit: "cores"
            }
          },
          %Variation{
            id: :memory,
            description: "Memory — 128 MB snap",
            attributes: %{
              id: "memory",
              name: "resources[memory_mb]",
              label: "Memory",
              value: "512",
              min: "128",
              max: "65536",
              step: "128",
              unit: "MB"
            }
          },
          %Variation{
            id: :storage,
            description: "Storage — 0 GB is legal (config-only apps)",
            attributes: %{
              id: "storage",
              name: "resources[storage_gb]",
              label: "Storage",
              value: "0",
              min: "0",
              max: "10240",
              step: "5",
              unit: "GB"
            }
          },
          %Variation{
            id: :no_unit,
            description: "Unit-less — the readout is the bare value",
            attributes: %{
              id: "volumes",
              name: "volumes",
              label: "Volumes",
              value: "2",
              min: "0",
              max: "10",
              step: "1"
            }
          }
        ]
      }
    ]
  end
end
