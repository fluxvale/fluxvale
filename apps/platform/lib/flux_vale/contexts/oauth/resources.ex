defmodule FluxVale.OAuth.Resources do
  @moduledoc """
  The resource-indicator allowlist for the MCP OAuth flow (#766,
  RFC 8707).

  One authorization server serves the prod and staging MCP hosts; the
  configured list is the whole audience set. A request may omit
  `resource` (older clients predate RFC 8707 support) — the AS then
  binds the token to the default (first) entry and records
  `resource_defaulted` in the audit row. A PRESENT value must match
  exactly; anything else is `invalid_target`.

  Runtime config comes from `MCP_RESOURCE_URLS` (comma-separated) in
  `config/runtime.exs`; the module-level default keeps tests and a
  bare dev shell honest.
  """

  @default_resource "https://mcp.fluxvale.com/mcp"

  @doc "Every configured resource identifier, in preference order."
  @spec configured() :: [String.t()]
  def configured do
    urls =
      :flux_vale
      |> Application.get_env(:mcp_oauth, [])
      |> Keyword.get(:resource_urls, [@default_resource])
      |> Enum.reject(&(&1 in [nil, ""]))

    case urls do
      [] -> [@default_resource]
      configured -> configured
    end
  end

  @doc "The resource a request binds to when it omits the parameter."
  @spec default() :: String.t()
  def default, do: hd(configured())

  @doc "Is `resource` one of the configured identifiers?"
  @spec valid?(term()) :: boolean()
  def valid?(resource) when is_binary(resource), do: resource in configured()
  def valid?(_resource), do: false
end
