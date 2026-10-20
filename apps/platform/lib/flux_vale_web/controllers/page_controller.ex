defmodule FluxValeWeb.PageController do
  use FluxValeWeb, :controller

  # :page_title carries the brand because the root layout's <title> swaps
  # its default for this assign — "Managed hosting…" alone would drop
  # "FluxVale" from the tab title. :page_description is the SEO hook; the
  # root layout will render it as a meta tag with the SEO slice (#164).
  def home(conn, _params) do
    conn
    |> assign(:page_title, "FluxVale — Managed hosting for open source applications")
    |> assign(
      :page_description,
      "Browse a curated catalog of open source apps, deploy one in minutes, " <>
        "and let FluxVale keep it running for you."
    )
    |> render(:home)
  end
end
