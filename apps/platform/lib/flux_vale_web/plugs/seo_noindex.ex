defmodule FluxValeWeb.Plugs.SeoNoindex do
  @moduledoc """
  ADR-00025 §4: every non-prod host is noindex — a `X-Robots-Tag:
  noindex, nofollow` header plus the `:robots_noindex` assign the root
  layout's seo tags turn into a `<meta name="robots">`. Covers
  `staging.*`, `pr-*.review.*` (which duplicate the whole site per PR!),
  and local dev hosts; a no-op on the canonical prod host.
  """

  import Plug.Conn

  # Baked at compile time — the canonical host is static config
  # (config.exs), never per-environment.
  @canonical_host Application.compile_env(:flux_vale, :canonical_host, "fluxvale.com")

  @doc false
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @doc "Marks every response from a non-canonical host as noindex."
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  # Host headers are case-insensitive (RFC 9110 §7.2) and neither Bandit
  # nor Plug downcases them — compare normalized.
  def call(%Plug.Conn{host: host} = conn, _opts) do
    if String.downcase(host, :ascii) == @canonical_host do
      conn
    else
      conn
      |> put_resp_header("x-robots-tag", "noindex, nofollow")
      |> assign(:robots_noindex, true)
    end
  end
end
