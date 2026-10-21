defmodule FluxValeWeb.Storybook.Components.NavLink do
  @moduledoc """
  Nav link stories — the app chrome's navigation unit.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.nav_link/1
  def render_source, do: :function

  def template do
    """
    <div class="flex items-center gap-1 rounded-xl border border-line bg-panel px-3 py-2"><.psb-variation/></div>
    """
  end

  def variations do
    [
      %VariationGroup{
        id: :states,
        description: "Resting vs active",
        variations: [
          %Variation{id: :resting, attributes: %{href: "#"}, slots: ["Catalog"]},
          %Variation{id: :active, attributes: %{href: "#", active: true}, slots: ["Catalog"]}
        ]
      }
    ]
  end
end
