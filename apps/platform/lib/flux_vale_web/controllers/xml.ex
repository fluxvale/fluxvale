defmodule FluxValeWeb.XML do
  @moduledoc """
  Shared XML escaping for the two plain-module XML builders — the
  sitemap (`FluxValeWeb.SitemapXML`) and the Atom feed
  (`FluxValeWeb.AtomFeed`). Neither is a HEEx template: LiveView's
  root-tag attribute injection (`phx-r`, a valueless attribute) breaks
  XML well-formedness, so both build iodata by hand and both need the
  same escaping — one home for it.
  """

  @doc """
  Escapes the five XML specials (`& < > " '`), safe for both text
  content and double-quoted attribute values.
  """
  @spec escape(String.t()) :: String.t()
  def escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
