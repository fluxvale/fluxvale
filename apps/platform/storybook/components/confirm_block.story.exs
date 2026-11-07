defmodule FluxValeWeb.Storybook.Components.ConfirmBlock do
  @moduledoc """
  Confirm block stories — the destructive confirm treatment, shaped like
  the backups panel's two confirms.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.confirm_block/1
  def render_source, do: :function
  def layout, do: :one_column

  def template do
    """
    <div class="max-w-md space-y-3"><.psb-variation/></div>
    """
  end

  def variations do
    [
      %Variation{
        id: :stop_backups,
        description: "Stop backups, with a note",
        attributes: %{
          title: "Stop backing this app up?",
          body:
            "This app stops backing up and the schedule is removed. Snapshots already in your bucket stay there.",
          note:
            "Keep your backup password. You'll still need it to restore these snapshots into a new app.",
          action: "Yes, stop backing up",
          event: "remove-settings",
          action_testid: "story-stop-confirm",
          cancel_testid: "story-stop-cancel",
          myself: nil
        }
      },
      %Variation{
        id: :restore,
        description: "Restore a backup, without a note",
        attributes: %{
          title: "Restore a backup?",
          body:
            "This replaces the app's current data with the backup from tonight. This cannot be undone.",
          action: "Yes, restore this backup",
          event: "restore",
          action_testid: "story-restore-confirm",
          cancel_testid: "story-restore-cancel",
          myself: nil
        }
      }
    ]
  end
end
