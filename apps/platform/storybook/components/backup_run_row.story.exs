defmodule FluxValeWeb.Storybook.Components.BackupRunRow do
  @moduledoc """
  Backup-run row stories — the backups panel's history line (#222,
  ADR-0037).

  The stories use hand-built `BackupRun` structs: the row renders from the
  run's own fields (no reads), so a story needs no database. Timestamps
  are fixed instants, not the wall clock, so the relative labels ("2 h
  ago") stay stable between screenshots.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.InstanceLive.BackupsComponent.backup_run_row/1
  def render_source, do: :function

  # One fixed "now" for every variation: the labels are relative, so a
  # drifting clock would drift the story.
  @now ~U[2026-10-24 04:00:00Z]

  def variations do
    [
      %VariationGroup{
        id: :outcomes,
        description: "Every terminal and in-flight state the sweep writes",
        variations: [
          %Variation{
            id: :scheduled_succeeded,
            attributes: attributes(run(:scheduled, :succeeded))
          },
          %Variation{id: :manual_succeeded, attributes: attributes(run(:manual, :succeeded))},
          %Variation{id: :running, attributes: attributes(run(:scheduled, :running))},
          %Variation{id: :queued, attributes: attributes(run(:manual, :pending))},
          %Variation{id: :failed, attributes: attributes(failed_run())},
          %Variation{id: :restore, attributes: attributes(restore_run())}
        ]
      },
      %VariationGroup{
        id: :edge_cases,
        description: "Shapes the panel must survive",
        variations: [
          %Variation{
            id: :failed_without_summary,
            description: "A failure with no reported reason",
            attributes: attributes(%{failed_run() | error_summary: nil})
          },
          %Variation{
            id: :long_error_summary,
            description: "The 500-char error_summary bound — the row wraps it",
            attributes:
              attributes(%{
                failed_run()
                | error_summary:
                    String.duplicate(
                      "exit code 1: unable to open config file — repository lock held by another process. ",
                      6
                    )
              })
          },
          %Variation{
            id: :fresh,
            description: "Just-finished (the sweep's own write lands here)",
            attributes:
              attributes(%{run(:scheduled, :succeeded) | finished_at: ~U[2026-10-24 03:59:40Z]})
          }
        ]
      }
    ]
  end

  defp attributes(run), do: %{run: run, now: @now}

  defp run(kind, status) do
    %FluxVale.Infrastructure.BackupRun{
      kind: kind,
      status: status,
      snapshot_id: if(status == :succeeded, do: "6b757e02e6a7c1d8aa0c3a1d5f7e9b2c", else: nil),
      bytes_added: if(status == :succeeded, do: 2_411_724, else: nil),
      started_at: ~U[2026-10-24 02:00:00Z],
      finished_at: if(status in [:succeeded, :failed], do: ~U[2026-10-24 02:04:10Z], else: nil)
    }
  end

  defp failed_run do
    %{
      run(:scheduled, :failed)
      | error_summary: "exit code 1: repository is already locked by another process"
    }
  end

  defp restore_run do
    %{
      run(:restore, :succeeded)
      | bytes_restored: 9_437_184,
        bytes_added: nil,
        restored_from: :running
    }
  end
end
