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

  Accepted with the ADR-0049 delegation: the SDK plug trusts the
  client-supplied x-posthog-distinct-id / x-posthog-session-id tracing
  headers (unsent by our frontend today, so today it is only spoof
  surface into our own project's error attribution) and ships the
  leftmost X-Forwarded-For entry as $ip to PostHog Cloud EU. The query
  string is NOT shipped (see call/2): this app's query strings carry
  auth-boundary tokens (#408's invitation accept). Revisit trigger:
  S1b's facade wiring is when the header trust and the $ip payload get
  a deliberate look rather than the SDK default.
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
        # The query string routinely carries auth-boundary tokens
        # (#408: the invitation accept route rides ?token=… and that
        # token IS the credential) — the context keeps the path, never
        # the query. A key denylist would miss the next token-bearing
        # param; dropping the query is the posture that doesn't need
        # revisiting. The real conn continues downstream untouched —
        # only the clone the SDK plug reads is stripped.
        conn_without_query = %{conn | query_string: ""}

        @posthog_plug.call(conn_without_query, opts)
    end
  end
end
