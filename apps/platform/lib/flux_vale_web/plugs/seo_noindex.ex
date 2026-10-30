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

  @doc """
  Is the request served on the canonical prod host? Shared by the
  noindex gate and the blog's draft visibility (ADR-00025 §1: drafts
  render only on non-prod hosts) — one predicate, one notion of "prod
  host"; the two rules can never fork.
  """
  @spec canonical_host?(Plug.Conn.t()) :: boolean()
  def canonical_host?(%Plug.Conn{host: host}) do
    String.downcase(host, :ascii) == @canonical_host
  end

  @doc "Marks every response from a non-canonical host as noindex."
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  # Host headers are case-insensitive (RFC 9110 §7.2) and neither Bandit
  # nor Plug downcases them — canonical_host?/1 normalizes the compare.
  def call(%Plug.Conn{} = conn, _opts) do
    if canonical_host?(conn) do
      conn
    else
      conn
      |> put_resp_header("x-robots-tag", "noindex, nofollow")
      |> assign(:robots_noindex, true)
    end
  end
end
