defmodule FluxValeWeb.EdgeWakeHTML do
  @moduledoc """
  The waking interstitial (#203, ADR-0036) — the few seconds between a
  visitor's request and the app's first answer. Standalone HTML (no
  app chrome, no LiveView socket, no JS): a meta refresh polls this
  same URL until the platform answers a redirect onto the app.

  Styling: utility classes from the platform's compiled app.css (the
  response is served by the platform, so /assets resolves) — the amber
  tokens, no new CSS surface.
  """

  use FluxValeWeb, :html

  embed_templates("edge_wake_html/*")

  @status_titles %{service_unavailable: "Fast asleep", found: "Ready"}

  @doc "One title per interstitial status — kept beside its template."
  @spec status_title(atom()) :: String.t()
  def status_title(status), do: Map.get(@status_titles, status, "Unavailable")
end
