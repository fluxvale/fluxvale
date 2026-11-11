defmodule FluxValeWeb.Plugs.PostHogIdentity do
  @moduledoc """
  Identity for PostHog error tracking (ADR-0049): the resolved user
  becomes the process's distinct_id, so a captured exception is
  attributed to the visitor it happened to.

  No-op while PostHog is unarmed (the runtime gate — the pipeline list
  is compile-static, same glue rationale as PostHogRequestContext) or
  the request has no resolved user. The context is process-scoped:
  LiveView processes do NOT inherit it — each LiveView sets its own
  distinct_id (the S1b facade's job, deliberately not this plug's).
  """

  @doc false
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @doc false
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case {Application.get_env(:flux_vale, :posthog), conn.assigns[:current_user]} do
      {nil, _unarmed} ->
        conn

      {_armed, nil} ->
        conn

      {_armed, user} ->
        PostHog.set_context(%{distinct_id: user.id})
        conn
    end
  end
end
