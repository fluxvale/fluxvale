defmodule FluxValeWeb.Storybook.Components.Flash do
  @moduledoc """
  Flash/toast stories — info and error notices.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.flash/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :info,
        description: "Info toast (fixed top-right in the app)",
        attributes: %{flash: %{"info" => "Instance forgejo-prod is now running."}}
      },
      %Variation{
        id: :error,
        description: "Error toast",
        attributes: %{flash: %{"error" => "Deploy failed — cluster quota exceeded."}}
      },
      %Variation{
        id: :titled,
        description: "With a title",
        attributes: %{
          flash: %{"error" => "Check your wallet balance and try again."},
          title: "Deploy failed"
        }
      }
    ]
  end
end
