defmodule FluxValeWeb.Storybook.Components.ReadonlyField do
  @moduledoc """
  Read-only credential/value field stories — the backups panel's summary
  row (#222, ADR-0037).

  Same shape as the file-access panel's credential rows (#190, ADR-0035
  Am. 1): the value is a no-wrap code block, so a long endpoint, bucket or
  key is never broken mid-string when someone selects it by hand.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.InstanceLive.BackupsComponent.readonly_field/1
  def render_source, do: :function

  def variations do
    [
      %VariationGroup{
        id: :backups_summary,
        description: "The three destination fields the panel shows",
        variations: [
          %Variation{
            id: :endpoint,
            attributes: %{
              label: "Endpoint",
              value: "https://account.r2.cloudflarestorage.com",
              testid: "story-backup-endpoint"
            }
          },
          %Variation{
            id: :bucket_with_prefix,
            attributes: %{
              label: "Bucket",
              value: "fluxvale-kavita",
              hint: "Folder: fluxvale/kavita",
              testid: "story-backup-bucket"
            }
          },
          %Variation{
            id: :masked_access_key,
            description: "The row's only credential-ish value: last four characters",
            attributes: %{
              label: "Access key id",
              value: "••••MPLE",
              hint: "Last four characters only",
              testid: "story-backup-access-key"
            }
          }
        ]
      },
      %VariationGroup{
        id: :overflow,
        description: "Long values scroll inside the block instead of wrapping",
        variations: [
          %Variation{
            id: :long_value,
            attributes: %{
              label: "Endpoint",
              value: "https://a-rather-long-account-id-0123456789.r2.cloudflarestorage.com:443",
              testid: "story-backup-endpoint-long"
            }
          },
          %Variation{
            id: :short_value,
            attributes: %{label: "Bucket", value: "b", testid: "story-backup-bucket-short"}
          }
        ]
      }
    ]
  end
end
