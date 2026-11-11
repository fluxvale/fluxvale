defmodule FluxValeWeb.AppAnalytics do
  @moduledoc """
  In-app analytics (ADR-0049): one hidden hook element carrying the
  armed PostHog config to app.js, which inits the bundled posthog-js
  only when the element is present. Cookieless posture: nothing
  persists on the visitor's device (memory persistence, no person
  profiles — the SDK's boot probes storage support with two anonymous
  write-and-immediately-remove keys, which no config gates), session
  recording is off, and identity rides events as an attribute only —
  app.js owns those switches; this component hands over nothing but
  what the server already knows.

  Unset config renders nothing at all — no element, no posthog boot,
  the kill switch's client half. There is no script tag here (the SDK
  and its tracing-headers patch ride the app.js bundle, and external
  dependency loading is disabled — nothing loads from third-party hosts
  at runtime), so Umami stays the ONLY external script (#576's
  exception). The hook renders from the app chrome (`Layouts.app`)
  alone: the public surface is Umami's per ADR-0049's layering, and
  emails carry no client at all.
  """

  use FluxValeWeb, :html

  attr(:current_user, :map, default: nil)

  @doc """
  The hook element, rendered only while the :posthog app env is armed
  with BOTH halves — a partial map (either key missing or blank)
  renders nothing, same atomic-pair stance as SiteAnalytics. Read at
  render time (runtime config, never compile-time).
  """
  @spec app_analytics(map()) :: Phoenix.LiveView.Rendered.t()
  def app_analytics(assigns) do
    config = Application.get_env(:flux_vale, :posthog)

    assigns =
      assign(assigns,
        armed?: armed?(config),
        api_host: config && Map.get(config, :api_host),
        api_key: config && Map.get(config, :api_key),
        distinct_id: distinct_id(assigns[:current_user])
      )

    ~H"""
    <%= if @armed? do %>
      <div
        id="posthog-config"
        data-api-host={@api_host}
        data-api-key={@api_key}
        data-distinct-id={@distinct_id}
        hidden
      >
      </div>
    <% end %>
    """
  end

  # Attribution only, never auth (the SDK's own stance): the resolved
  # user's id, the same value PostHogIdentity stamps as distinct_id
  # server-side (public pipelines today; the LiveView facade is S1b's),
  # so client and server events can correlate on one id. The id is not
  # a secret; it already rides every server-side error event. Map.get,
  # not .id: the layout attr is a plain :map and only the id is read
  # here (chrome probes render partial users) — a user without an id
  # renders the hook without the attribute.
  defp distinct_id(nil), do: nil
  defp distinct_id(user), do: Map.get(user, :id)

  defp armed?(%{} = config) do
    not blank?(Map.get(config, :api_host)) and not blank?(Map.get(config, :api_key))
  end

  defp armed?(_), do: false

  defp blank?(value), do: value in [nil, ""]
end
