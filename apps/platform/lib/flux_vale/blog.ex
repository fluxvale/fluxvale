defmodule FluxVale.Blog do
  @moduledoc """
  The blog's public seam (ADR-00025 §1): boot-compiled markdown posts
  served as server-rendered HTML at `/blog` — no LiveView, zero client
  JS, crawlers get the full document. Reads are persistent_term
  lookups. Web-layer callers use this module, never the Loader/Lint
  internals; `draft` visibility is the caller's policy call (the
  controller: drafts render only off the canonical host, ADR-00025 §4
  preview surfaces).
  """

  alias FluxVale.Blog.Loader
  alias FluxVale.Blog.Post

  @doc "Every loaded post, newest first (drafts included)."
  @spec all() :: [Post.t()]
  def all, do: Loader.loaded()

  @doc "Published posts only — the sitemap, feed, and prod-index set."
  @spec published() :: [Post.t()]
  def published, do: Enum.reject(all(), & &1.draft)

  @doc "One post by slug, draft or not; `nil` when absent."
  @spec get(String.t()) :: Post.t() | nil
  def get(slug), do: Enum.find(all(), &(&1.slug == slug))

  @doc """
  Dev-only hot reload (`blog_hot_reload: true` in dev.exs): stat-check
  the content dir and recompile when it changed, so writing a post
  locally needs no restart. The flag is unset in test/prod — a no-op
  there, and no reload cost on the hot path.
  """
  @spec maybe_hot_reload() :: :ok
  def maybe_hot_reload do
    if Application.get_env(:flux_vale, :blog_hot_reload, false) do
      Loader.reload_if_changed!()
    else
      :ok
    end
  end
end
