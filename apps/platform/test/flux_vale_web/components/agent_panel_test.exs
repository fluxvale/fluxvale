defmodule FluxValeWeb.Components.AgentPanelTest do
  @moduledoc false

  # #817: the omitted-slot degradation the onboarding modal relies on —
  # without the inner slot the body renders the full panel and none of
  # /agent's dismissal.

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias FluxValeWeb.AgentPanel

  @attrs %{
    prompt: "Finish setup with your agent.",
    snippets: [],
    snippet_note: "The snippets carry FLUXVALE_PAT by name — never a token value.",
    what_it_will_do: ["Check your wallet and stop at zero"]
  }

  defp render_body do
    html = render_component(&AgentPanel.body/1, @attrs)
    LazyHTML.from_fragment(html)
  end

  test "without the inner slot the panel renders and the dismissal does not" do
    doc = render_body()

    for testid <- ~w(agent-prompt agent-what-it-will-do agent-spend-rule) do
      nodes = LazyHTML.query(doc, "[data-testid='#{testid}']")
      assert Enum.to_list(nodes) != []
    end

    dismissed = LazyHTML.query(doc, "[data-testid='agent-dismiss']")
    assert Enum.to_list(dismissed) == []
  end
end
