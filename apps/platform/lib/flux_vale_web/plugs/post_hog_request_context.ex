defmodule FluxValeWeb.Plugs.PostHogRequestContext do
  @moduledoc """
  Request context for PostHog error tracking (ADR-0049): delegates to
  the SDK's `PostHog.Integrations.Plug` ($current_url, $pathname, $ip,
  request method, tracing headers), so a captured exception knows the
  request it happened in.

  Hand-written glue because the gate is runtime (POSTHOG_API_KEY in
  runtime.exs) while the endpoint's plug list is compile-static: the
  wrapper re-reads the app env per request and passes the conn through
  untouched while PostHog is unarmed.
  """

  # The SDK's request-context plug — via attribute so neither the
  # nested-module-alias check nor an `:as` alias is needed.
  @posthog_plug PostHog.Integrations.Plug

  @doc false
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @doc false
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    case Application.get_env(:flux_vale, :posthog) do
      nil ->
        conn

      _armed ->
        @posthog_plug.call(conn, opts)
    end
  end
end
