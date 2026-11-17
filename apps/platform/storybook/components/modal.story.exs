defmodule FluxValeWeb.Storybook.Components.Modal do
  @moduledoc """
  Modal stories — the #817 house dialog: a native `<dialog>` opened with
  `showModal()` by the colocated `.Modal` hook, closed by the close
  button, Escape, or a backdrop click (panel clicks don't dismiss).

  The storybook pages run the storybook's own tool JS (the dep's, not
  app.js), so the colocated hook doesn't fire here — these stories show
  the dialog's closed shell with its content in the markup. The open
  state's living reference is the app itself: the dashboard's fresh
  empty state (the button opens it over the page).
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.modal/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :default,
        description: "Body + footer link (the #817 agent handoff shape)",
        attributes: %{
          id: "story-modal",
          title: "Finish setup with your agent",
          on_cancel: "close-modal"
        },
        slots: [
          """
          <p class="text-sm text-ink-muted">Copy the prompt below.</p>
          <:footer>
            <.link
              navigate="#"
              class="text-sm font-medium text-link transition-colors hover:text-ink"
            >
              Open the full page
            </.link>
          </:footer>
          """
        ]
      },
      %Variation{
        id: :body_only,
        description: "Body only, no footer",
        attributes: %{
          id: "story-modal-plain",
          title: "Confirm the spend",
          on_cancel: "close-modal"
        },
        slots: ["The agent asks before it spends — never deploys without an explicit yes."]
      }
    ]
  end
end
