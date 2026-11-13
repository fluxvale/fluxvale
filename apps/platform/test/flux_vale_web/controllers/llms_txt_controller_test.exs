defmodule FluxValeWeb.LlmsTxtControllerTest do
  @moduledoc false

  # /llms.txt (#765): plain text, no HTML negotiation, the same prompt
  # the panel and /docs/agents render, and links that resolve.

  use FluxValeWeb.ConnCase, async: true

  alias FluxValeWeb.AgentPrompt

  test "serves the machine-readable prompt as text/plain", %{conn: conn} do
    conn = get(conn, ~p"/llms.txt")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]

    body = conn.resp_body
    assert body =~ "# FluxVale"
    assert body =~ AgentPrompt.prompt(AgentPrompt.public_context())
    assert body =~ "MCP server: #{AgentPrompt.mcp_url()}"
  end

  test "an agent sending Accept: text/plain is not refused", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "text/plain")
      |> get(~p"/llms.txt")

    assert response(conn, 200)
  end

  test "every doc link in the body resolves", %{conn: _conn} do
    body = AgentPrompt.llms_txt(AgentPrompt.public_context())
    links = AgentPrompt.links(AgentPrompt.public_context())

    for {_title, url} <- links do
      assert body =~ url
      path = String.replace_prefix(url, FluxValeWeb.Endpoint.url(), "")
      assert path =~ ~r"^/docs/"

      conn = get(build_conn(), path)
      assert response(conn, 200), "#{path} did not resolve"
    end
  end
end
