defmodule FluxValeWeb.Storybook.Components.EmptyState do
  @moduledoc """
  Empty state stories — zero-CONTENT placeholders.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.empty_state/1
  def render_source, do: :function

  def template do
    """
    <div class="max-w-md"><.psb-variation/></div>
    """
  end

  def variations do
    [
      %Variation{
        id: :default,
        description: "Title + supporting copy",
        attributes: %{title: "No instances yet"},
        slots: ["Deploy your first app from the catalog."]
      },
      %Variation{
        id: :title_only,
        description: "Title only",
        attributes: %{title: "No apps in the catalog yet"}
      }
    ]
  end
end
