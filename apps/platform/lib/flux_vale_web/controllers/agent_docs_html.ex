defmodule FluxValeWeb.AgentDocsHTML do
  @moduledoc """
  Templates for `/docs/agents` (#765) — the impersonal public guide (#817).
  """

  use FluxValeWeb, :html

  embed_templates("agent_docs_html/*")
end
