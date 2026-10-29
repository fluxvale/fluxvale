defmodule FluxValeWeb.AccessWakeHTML do
  @moduledoc """
  The gateway wake's interstitial (#273, ADR-0039 §6) — the few seconds
  between a tailnet request and the app's first answer. Standalone HTML
  (no app chrome, no LiveView socket, no JS): a meta refresh polls this
  same URL until serve's flipped config answers with the app instead.

  Styling: inline, deliberately (the same stance as the edge wake's
  pages) — while asleep the visitor's URL is the gateway's tailnet name
  proxied onto this endpoint, so an external stylesheet link would route
  back into this very controller. Nothing external, nothing to fetch.
  """

  use FluxValeWeb, :html

  embed_templates("access_wake_html/*")

  @status_titles %{service_unavailable: "Fast asleep"}

  @doc "One title per interstitial status — kept beside its template."
  @spec status_title(atom()) :: String.t()
  def status_title(status), do: Map.get(@status_titles, status, "Unavailable")
end
