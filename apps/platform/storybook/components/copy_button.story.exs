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
          value: "https://empty-dust-9937.fluxvale.lvh.me/dav",
          testid: "story-copy"
        }
      },
      %Variation{
        id: :custom_label,
        description: "A labeled copy affordance",
        attributes: %{
          id: "story-copy-labeled",
          value: "fluxvale",
          label: "Copy username",
          testid: "story-copy-labeled"
        }
      },
      %Variation{
        id: :in_situ,
        description: "In situ: a credential row as the instance page renders it",
        slots: [
          """
          <div class="grid gap-1.5 text-sm">
            <span class="text-ink-subtle">Password</span>
            <div class="flex items-start gap-2">
              <code class="min-w-0 flex-1 overflow-x-auto rounded-md border border-line bg-panel-raised px-2 py-1 font-mono text-xs whitespace-nowrap text-ink">
                Fc44P6AivIUSZOMD8c6wutPfHhnHAX6cjKq9jWD8qr8
              </code>
              <.copy_button
                id="story-copy-in-situ"
                value="Fc44P6AivIUSZOMD8c6wutPfHhnHAX6cjKq9jWD8qr8"
                testid="story-copy-in-situ"
                label="Copy password"
              />
            </div>
          </div>
          """
        ]
      }
    ]
  end
end
