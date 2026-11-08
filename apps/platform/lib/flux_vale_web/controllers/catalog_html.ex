defmodule FluxValeWeb.CatalogHTML do
  @moduledoc """
  The public catalog pages (#164): SSR mirrors of the authenticated
  CatalogLive browse — the programmatic-SEO surface anonymous visitors
  and crawlers read.
  """

  use FluxValeWeb, :html

  alias FluxValeWeb.CatalogPageComponents

  embed_templates("catalog_html/*")

  defp sort_by_name(apps), do: Enum.sort_by(apps, & &1.name)
end
