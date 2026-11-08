defmodule FluxVale.Seeds.CatalogScreenshotsTest do
  @moduledoc """
  #611 S1's CI gate (plan §4.3): every seeded `screenshots.src` must
  resolve to a shipped static file under `priv/static`. Vacuous until
  the S7 content pass seeds screenshots — an empty list passes by
  design, and S7 turns this into a real check with no test change.
  """

  use ExUnit.Case, async: true

  alias FluxVale.Seeds.CatalogData

  test "every seeded screenshots.src resolves to a shipped static file" do
    static_root = Application.app_dir(:flux_vale, "priv/static")

    srcs = screenshot_srcs(CatalogData.entries())

    # Vacuous until S7: with no seeded screenshots this loops zero
    # times, and each S7 capture makes it assert one more file.
    for src <- srcs do
      # src is app-absolute; expand relative to the static root (the
      # blog lint's og_image stance), and keep the containment check a
      # `..`-segment src can never slip past (the type's shape regex
      # alone admits them — hostile review #326's hygiene class).
      relative = String.trim_leading(src, "/")
      expanded = Path.expand(relative, static_root)

      assert String.starts_with?(expanded, Path.expand(static_root)),
             "#{src} must resolve inside the static root"

      assert File.exists?(expanded), "#{src} does not resolve to a shipped static file"
    end
  end

  defp screenshot_srcs(entries) do
    for entry <- entries,
        app <- entry.apps,
        screenshot <- app.screenshots,
        do: screenshot["src"]
  end
end
