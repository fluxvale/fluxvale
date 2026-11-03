defmodule FluxValeWeb.MCP.Origins do
  @moduledoc """
  The MCP endpoint's browser-origin gate (#361, ADR-0019 §3) — the
  `origins:` MFA `Phantom.Plug` calls per request. Membership in the
  `:mcp_origins` application env list, so the deployment's allowlist
  is config, not code: config.exs defaults it to the canonical prod
  origin; config/runtime.exs replaces it where the deployment serves
  a non-canonical browser origin (staging, PR envs). MCP clients send
  no Origin at all — phantom allows its absence; browsers are the only
  surface this gates.
  """

  @spec allowed?(String.t()) :: boolean()
  def allowed?(origin), do: origin in origins()

  defp origins, do: Application.get_env(:flux_vale, :mcp_origins, [])
end
