defmodule FluxValeWeb.Storybook.Components.DavSnippet do
  @moduledoc """
  Dav snippet stories — the file-access panel's per-platform rclone
  quick-start (#253, ADR-0035 Am. 3).

  One variation per active tab; each shows its platform's five-step
  sequence with the panel's example instance values inline. `on_select`
  and `on_detect` stay unset — the workshop sandbox has no host
  LiveView to take those events, so the tabs render in their inert
  (storybook) shape. The instance page is the live one.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.InstanceLive.DavSnippet.dav_snippet/1

  def render_source, do: :function

  # The copy_button story's example instance, kept identical so the
  # credential rows across stories read as the same fake customer.
  @url "https://empty-dust-9937.fluxvale.lvh.me/dav"

  def variations do
    [
      %Variation{
        id: :windows,
        description: "Windows tab active — PowerShell shapes, one-line connect",
        attributes: attributes(id: "story-dav-windows", platform: :windows)
      },
      %Variation{
        id: :macos,
        description: "macOS tab active — Homebrew install, POSIX paths",
        attributes: attributes(id: "story-dav-macos", platform: :macos)
      },
      %Variation{
        id: :linux,
        description: "Linux tab active — the install script, the no-JS default",
        attributes: attributes(id: "story-dav-linux", platform: :linux)
      },
      %Variation{
        id: :macos_revealed,
        description: "macOS tab with the password revealed — it rides the connect command",
        attributes:
          attributes(
            id: "story-dav-macos-revealed",
            platform: :macos,
            password: "EXAMPLEnotARealCredential000000000000000000"
          )
      }
    ]
  end

  defp attributes(overrides) do
    %{
      id: "story-dav",
      platform: :linux,
      url: @url,
      username: "fluxvale",
      password: nil,
      remote: "fluxvale-empty-dust-9937"
    }
    |> Map.merge(Map.new(overrides))
  end
end
