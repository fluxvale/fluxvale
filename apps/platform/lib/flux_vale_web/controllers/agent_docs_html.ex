defmodule FluxValeWeb.AgentDocsHTML do
  @moduledoc """
  Templates for `/docs/agents` (#765) — the public agent handoff page.
  """

  use FluxValeWeb, :html

  embed_templates("agent_docs_html/*")
end
