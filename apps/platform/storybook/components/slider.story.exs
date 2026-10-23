defmodule FluxValeWeb.Storybook.Components.Slider do
  @moduledoc """
  Slider stories — the selectable discrete control (#195, rungs-only
  #221: the thumb stops on the ladder's labeled rungs).
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
        description: "The deploy wizard's three dimensions (#221 — the seeded ladder's rungs)",
        variations: [
          %Variation{
            id: :cpu,
            description: "CPU — 0.25→4 cores, stopped mid-ladder at 1",
            attributes: %{
              id: "cpu",
              name: "resources[cpu_cores]",
              label: "CPU cores",
              value: "1",
              values: ["0.25", "0.5", "1", "2", "4"],
              unit: "cores"
            }
          },
          %Variation{
            id: :memory,
            description: "Memory — 512→8192 MB, stopped at 2048",
            attributes: %{
              id: "memory",
              name: "resources[memory_mb]",
              label: "Memory",
              value: "2048",
              values: ["512", "1024", "2048", "4096", "8192"],
              unit: "MB"
            }
          },
          %Variation{
            id: :storage,
            description: "Storage — 5→100 GB, stopped at the bottom rung",
            attributes: %{
              id: "storage",
              name: "resources[storage_gb]",
              label: "Storage",
              value: "5",
              values: ["5", "10", "20", "50", "100"],
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
              value: "3",
              values: ["0", "1", "2", "3", "4", "5"]
            }
          }
        ]
      }
    ]
  end
end
