defmodule FluxValeWeb.SiteAnalytics do
  @moduledoc """
  Site tracking for the public surface (#576): a Umami script tag whose
  source URL and website id come from runtime config alone — `nil`
  config renders no script at all, so staging and production stay
  silent until an operator sets both `UMAMI_SCRIPT_URL` and
  `UMAMI_WEBSITE_ID` (runtime.exs composes the pair).

  Umami sets no cookies or local storage on visitors, so the script
  element is the whole integration. It renders from the public chrome
  (`Layouts.public`) and the self-contained landing page, never from
  the authenticated app surface.
  """

  use FluxValeWeb, :html

  @typedoc "The rendered half of the pair: where the tracker loads from."
  @type script_url :: String.t()

  @typedoc "Umami's website id, the `data-website-id` the tracker reads."
  @type website_id :: String.t()

  @doc """
  Resolves the env pair into layout config — runtime.exs calls this at
  boot so the same question has one answering module (the Observability
  pattern; runtime.exs stays thin).

      * both present → `{:ok, [script_url:, website_id:]}`

      * both blank (nil or the empty-Secret `""`) → `:unset` — no
        script renders, the deliberate default everywhere

      * exactly one present → `{:error, :half_configured}` — runtime.exs
        warns and leaves the config unset rather than render a tag that
        cannot report (or block a boot on a typo, the METRICS_TOKEN
        stance vs the ACCESS_EDGE raise)

  """
  @spec from_env(String.t() | nil, String.t() | nil) ::
          {:ok, [{:script_url, script_url} | {:website_id, website_id}]}
          | :unset
          | {:error, :half_configured}
  def from_env(script_url, website_id) do
    case {blank?(script_url), blank?(website_id)} do
      {true, true} ->
        :unset

      {false, false} ->
        {:ok, [script_url: script_url, website_id: website_id]}

      _one_without_the_other ->
        {:error, :half_configured}
    end
  end

  defp blank?(value), do: value in [nil, ""]

  @doc """
  The tracker tag, rendered only when config carries both halves.
  Read at render time (runtime config, never compile-time).
  """
  @spec site_analytics(map()) :: Phoenix.LiveView.Rendered.t()
  def site_analytics(assigns) do
    config = Application.get_env(:flux_vale, :site_analytics, [])

    assigns =
      assign(assigns,
        script_url: config[:script_url],
        website_id: config[:website_id]
      )

    ~H"""
    <%= if @script_url && @website_id do %>
      <%!-- The tracker loads cross-origin from the analytics instance
      itself, so it cannot ride the app.js bundle (a bundled import
      would load on every surface and could never render "nothing at
      all" when unconfigured — both are the point of this component).
      `async` per Umami's embed snippet; cookieless, so no banner. --%>
      <script async src={@script_url} data-website-id={@website_id}>
      </script>
    <% end %>
    """
  end
end
