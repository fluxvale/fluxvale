defmodule FluxValeWeb.BlogHTML do
  @moduledoc """
  Templates for the blog's SSR pages (ADR-00025 §1).
  """

  use FluxValeWeb, :html

  embed_templates("blog_html/*")
end
