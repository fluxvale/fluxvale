defmodule FluxVale.Catalog.App.AbsolutizeIconUrl do
  @moduledoc """
  The JSON:API read shape for `App.icon_url` (#719): the stored value
  is an app-absolute vendored path (`Types.IconPath`), and the public
  API keeps handing every consumer an absolute URL — the JSON-LD
  screenshots' precedent (`CatalogController` prepends the canonical
  origin to each screenshot src).

  Attached only to the API's own reads (:api_list / :api_get_by_slug),
  so the SSR and deploy reads keep the stored path and the pages
  resolve icons same-origin (#718). The origin is the canonical one —
  staging serves prod URLs by design (ADR-00025) — read from the same
  `:flux_vale, :canonical_origin` key `FluxValeWeb.Seo.canonical_origin/0`
  bakes at compile time.

  Idempotent: an absent value, or a path that is already absolute (a
  pre-contract row the seed heals), passes through untouched. Filters
  and sorts still read the stored path — this shapes the response,
  not the column.
  """

  use Ash.Resource.Preparation

  @impl Ash.Resource.Preparation
  def prepare(query, _opts, _context) do
    Ash.Query.after_action(query, fn _query, apps ->
      {:ok, Enum.map(apps, &absolutize/1)}
    end)
  end

  defp absolutize(%{icon_url: "/" <> rest} = app) do
    %{app | icon_url: canonical_origin() <> "/" <> rest}
  end

  defp absolutize(app), do: app

  defp canonical_origin do
    Application.get_env(:flux_vale, :canonical_origin, "https://fluxvale.com")
  end
end
