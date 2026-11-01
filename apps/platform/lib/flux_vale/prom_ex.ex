defmodule FluxVale.PromEx do
  @moduledoc """
  The PromEx supervision tree (#98, ADR-0012): Phoenix/Ecto/Oban/BEAM
  metrics for Alloy to scrape at /metrics (PromEx.Plug in the router,
  pod Service annotations on the fleet side).

  Starts only when :prom_ex_enabled (FluxVale.Observability.prom_ex_child/0
  gates the child). While down, the plug answers 503 — scrape never
  sees a half-configured tree.
  """

  use PromEx, otp_app: :flux_vale

  # The Oban plugin stays fully qualified — aliasing it would shadow the
  # Oban engine name that `oban_supervisors` needs.
  alias PromEx.Plugins.Beam
  alias PromEx.Plugins.Ecto
  alias PromEx.Plugins.Phoenix

  @impl PromEx
  def plugins do
    [
      {Phoenix, endpoint: FluxValeWeb.Endpoint, router: FluxValeWeb.Router},
      {Ecto, repos: [FluxVale.Repo]},
      {PromEx.Plugins.Oban, oban_supervisors: [Oban]},
      {Beam, []},
      # #232: wake-latency histograms — the scale-to-zero SLI
      # (FluxVale.PromEx.Plugins.Wake owns the bucket/label contract).
      {FluxVale.PromEx.Plugins.Wake, []},
      # Business counters — the flux_vale_*_total families the fleet
      # PR's allowlist cites (narrower labels than LiveDashboard's).
      {FluxVale.PromEx.Plugins.Business, []}
    ]
  end
end
