defmodule FluxValeWeb.Storybook.Components.Input do
  @moduledoc """
  Input stories — text, select, textarea, checkbox, with error states.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.input/1
  def render_source, do: false
  def layout, do: :one_column

  def template do
    """
    <div class="max-w-md"><.psb-variation/></div>
    """
  end

  def variations do
    [
      %Variation{
        id: :text,
        attributes: %{label: "Instance name", type: "text", placeholder: "my-forgejo"},
        description: "Text input"
      },
      %Variation{
        id: :text_error,
        attributes: %{
          label: "Instance name",
          type: "text",
          value: "no",
          errors: ["must be at least 3 characters"]
        },
        description: "Errored field (danger border + message)"
      },
      %Variation{
        id: :select,
        attributes: %{
          label: "Customer type",
          type: "select",
          options: [{"Consumer", "consumer"}, {"Business", "business"}]
        },
        description: "Select"
      },
      %Variation{
        id: :textarea,
        attributes: %{label: "Release notes", type: "textarea", rows: "3"},
        description: "Textarea"
      },
      %Variation{
        id: :checkbox,
        attributes: %{label: "Send me deployment alerts", type: "checkbox", checked: true},
        description: "Checkbox"
      },
      %Variation{
        id: :text_disabled,
        attributes: %{
          label: "Instance name",
          type: "text",
          placeholder: "Unavailable while deploying",
          disabled: true
        },
        description: "Disabled field (50% wash, no focus ring)"
      }
    ]
  end
end
