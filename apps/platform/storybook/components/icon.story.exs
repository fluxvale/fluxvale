defmodule FluxValeWeb.Storybook.Components.Icon do
  @moduledoc """
  Icon stories — Heroicons via the `<.icon>` component.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.icon/1
  def render_source, do: :function

  def template do
    """
    <div class="flex items-center gap-3 text-ink"><.psb-variation/></div>
    """
  end

  def variations do
    [
      %VariationGroup{
        id: :common,
        description: "Common app icons (outline, size-5)",
        variations:
          for {id, name} <- [
                rocket: "hero-rocket-launch",
                server: "hero-server-stack",
                wallet: "hero-banknotes",
                catalog: "hero-squares-2x2",
                check: "hero-check-circle",
                warning: "hero-exclamation-triangle"
              ] do
            %Variation{id: id, attributes: %{name: name, class: "size-5"}}
          end
      }
    ]
  end
end
