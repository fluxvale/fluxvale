defmodule FluxValeWeb.Storybook.Components.CopyButton do
  @moduledoc """
  Copy-button stories — the credential-panel affordance (#194).

  The component carries its value in a `data-` attribute so a copy is
  always the exact rendered string, never a text selection (a wrapped
  43-char password triple-clicked with its label is what shipped 401s).
  The clipboard write needs a real browser; the stories show the resting
  and in-situ shapes.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.copy_button/1

  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :default,
        description: "Resting state",
        attributes: %{
          id: "story-copy",
          value: "https://empty-dust-9937.fluxvale.lvh.me/dav"
        }
      },
      %Variation{
        id: :custom_label,
        description: "A labeled copy affordance",
        attributes: %{
          id: "story-copy-labeled",
          value: "fluxvale",
          label: "Copy username"
        }
      },
      %Variation{
        id: :in_situ,
        description: "In situ: a credential row as the instance page renders it",
        attributes: %{
          id: "story-copy-in-situ",
          value: "EXAMPLEnotARealCredential000000000000000000",
          label: "Copy password"
        },
        # The credential row wraps the button (the instance page's
        # `dav_field/1` shape), so it rides a variation template, not slots.
        template: """
        <div class="grid gap-1.5 text-sm">
          <span class="text-ink-subtle">Password</span>
          <div class="flex items-start gap-2">
            <code class="min-w-0 flex-1 overflow-x-auto rounded-md border border-line bg-panel-raised px-2 py-1 font-mono text-xs whitespace-nowrap text-ink">
              EXAMPLEnotARealCredential000000000000000000
            </code>
            <.psb-variation />
          </div>
        </div>
        """
      }
    ]
  end
end
