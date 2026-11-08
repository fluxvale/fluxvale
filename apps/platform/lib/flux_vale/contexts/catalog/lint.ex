defmodule FluxVale.Catalog.Lint do
  @moduledoc """
  The curation lint (#611, plan §5): reports, per app, which curation
  tier the seed YAML reaches — minimum (today's contract), recommended
  (plus caveats and alternatives), full parity (plus screenshots,
  features, faq, in_action_intro, community_url). `mix catalog.lint`
  prints it.

  Informational by design (D1): omission is a designed state, so the
  report never fails a build — malformed content fails at write time
  through the types, which is the hard gate.
  """

  @recommended_fields [:caveats, :alternatives]
  @full_parity_fields [:community_url, :faq, :features, :in_action_intro, :screenshots]

  @type tier :: :minimum | :recommended | :full_parity

  @doc """
  One report line per app (slug-sorted) plus a summary line. Pure —
  the mix task only prints.
  """
  @spec report([map()]) :: [String.t()]
  def report(entries) do
    assessments =
      entries
      |> Enum.flat_map(& &1.apps)
      |> Enum.sort_by(& &1.slug)
      |> Enum.map(&assess/1)

    Enum.map(assessments, &line/1) ++ [summary(length(assessments), assessments)]
  end

  defp assess(app) do
    missing_recommended = missing(@recommended_fields, app)
    missing_full_parity = missing(@full_parity_fields, app)

    %{
      slug: app.slug,
      tier: tier(missing_recommended, missing_full_parity),
      missing_recommended: missing_recommended,
      missing_full_parity: missing_full_parity
    }
  end

  defp missing(fields, app) do
    fields
    |> Enum.reject(&present?(&1, app))
    |> Enum.sort()
  end

  # nil, [], and "" are the absent states (the loader's defaults);
  # anything else counts as authored.
  defp present?(field, app) do
    case Map.get(app, field) do
      nil -> false
      [] -> false
      "" -> false
      _authored -> true
    end
  end

  defp tier([], []), do: :full_parity
  defp tier([], _missing_full_parity), do: :recommended
  defp tier(_missing_recommended, _missing_full_parity), do: :minimum

  defp line(%{tier: :full_parity, slug: slug}), do: "#{slug}: full parity"

  defp line(%{tier: :recommended, slug: slug, missing_full_parity: missing}) do
    "#{slug}: recommended (missing for full parity: #{join_fields(missing)})"
  end

  defp line(%{
         tier: :minimum,
         slug: slug,
         missing_recommended: recommended,
         missing_full_parity: full_parity
       }) do
    "#{slug}: minimum (missing for recommended: #{join_fields(recommended)} | missing for full parity: #{join_fields(full_parity)})"
  end

  defp summary(count, assessments) do
    tallies = Map.new([:minimum, :recommended, :full_parity], &{&1, 0})

    counts =
      Enum.reduce(assessments, tallies, fn assessment, acc ->
        Map.update!(acc, assessment.tier, &(&1 + 1))
      end)

    "#{count} apps: #{counts.minimum} minimum, #{counts.recommended} recommended, #{counts.full_parity} full parity"
  end

  defp join_fields(fields), do: Enum.join(fields, ", ")
end
