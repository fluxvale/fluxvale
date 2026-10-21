defmodule FluxValeWeb.Storybook.Components.Table do
  @moduledoc """
  Table stories — the data surface (stream-ready).
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.table/1
  def render_source, do: :function
  def layout, do: :one_column

  # The slot markup composes other system components — import them so
  # <.status_badge/> resolves inside the story's HEEx.
  def imports, do: [{FluxValeWeb.CoreComponents, status_badge: 1}]

  def template do
    """
    <div class="w-full"><.psb-variation/></div>
    """
  end

  def variations do
    [
      %Variation{
        id: :instances,
        description: "In situ: an instance list",
        attributes: %{
          id: "sb-instances",
          rows: [
            %{
              id: 1,
              name: "forgejo-prod",
              slug: "forgejo-x2kc",
              app: "Forgejo",
              status: :running
            },
            %{
              id: 2,
              name: "vaultwarden",
              slug: "vaultwarden-9fqa",
              app: "Vaultwarden",
              status: :deploying
            },
            %{id: 3, name: "old-forge", slug: "forge-01d3", app: "Forgejo", status: :stopped}
          ]
        },
        slots: [
          """
          <:col :let={instance} label="Name">
            <span class="font-medium text-ink"><%= instance.name %></span>
            <span class="ml-2 font-mono text-xs text-ink-subtle"><%= instance.slug %></span>
          </:col>
          """,
          """
          <:col :let={instance} label="App"><%= instance.app %></:col>
          """,
          """
          <:col :let={instance} label="Status"><.status_badge status={instance.status}/></:col>
          """
        ]
      }
    ]
  end
end
