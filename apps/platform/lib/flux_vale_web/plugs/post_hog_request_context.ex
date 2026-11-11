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

  Accepted with the ADR-0049 delegation: the SDK plug ships the
  leftmost X-Forwarded-For entry as $ip to PostHog Cloud EU (documented
  acceptance; the project-level IP-off posture in the PostHog project
  settings is the real gate — revisit at S1b). The query string is NOT
  forwarded (see call/2) — that strip is permanent: this app's query
  strings carry auth-boundary tokens (#408's invitation accept).

  The x-posthog-distinct-id/-session-id tracing headers ARE forwarded
  since the client slice ships them deliberately (the bundled posthog-js
  sets tracing_headers to our own origin): they are attribution-only
  analytics context — the SDK's own docs say so, never auth — so
  forging them pollutes the forger's own browser session attribution,
  nothing more.
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
        # The SDK plug's only effect is process-scoped context-setting
        # (PostHog.Context.set -> logger metadata); it returns the conn
        # it was handed. So hand it a query-stripped VIEW and return the
        # REAL conn downstream untouched: the query string routinely
        # carries auth-boundary tokens (#408: invitation accept rides
        # ?token=… and that token IS the credential).
        @posthog_plug.call(%{conn | query_string: ""}, opts)

        conn
    end
  end
end
