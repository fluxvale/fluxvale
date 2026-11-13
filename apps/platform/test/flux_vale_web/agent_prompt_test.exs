defmodule FluxValeWeb.AgentPromptTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias FluxValeWeb.AgentPrompt

  setup do
    {:ok, ctx: AgentPrompt.context("Acme", "acme")}
  end

  test "the prompt carries the org, API base, MCP URL, and the first-run flow", %{ctx: ctx} do
    prompt = AgentPrompt.prompt(ctx)

    assert prompt =~ "Acme (acme)"
    assert prompt =~ "API base: #{ctx.api_base}"
    assert prompt =~ "MCP server: #{ctx.mcp_url}"
    assert prompt =~ "#{ctx.api_base}/billing/topup"
    assert prompt =~ "#{ctx.api_base}/docs/automation/terraform"

    assert prompt =~ "whoami"
    assert prompt =~ "wallet_balance"
    assert prompt =~ "apps_list"
    assert prompt =~ "apps_show"
    assert prompt =~ "monthly_cents"
    assert prompt =~ "row's `url`"
    assert prompt =~ "instances_deploy"
    assert prompt =~ "instances_configure"
    assert prompt =~ AgentPrompt.commit_rule()
  end

  test "the auth sentence is the one swappable PAT shape today", %{ctx: ctx} do
    note = AgentPrompt.auth_note(ctx)

    assert note =~ "#{ctx.api_base}/settings/developer#api-tokens"
    assert note =~ "FLUXVALE_PAT"
    assert note =~ "Authorization: Bearer $FLUXVALE_PAT"
    assert note =~ "OAuth ships"
    assert AgentPrompt.bearer_headers?()
    refute note =~ "fvpat_"
  end

  test "the client snippets assume the OAuth-shaped install and never hold a token", %{ctx: ctx} do
    claude = AgentPrompt.install(:claude_code, ctx)
    assert claude =~ "claude mcp add --transport http fluxvale #{ctx.mcp_url}"
    assert claude =~ ~s(--header "Authorization: Bearer $FLUXVALE_PAT")

    cursor = AgentPrompt.install(:cursor, ctx)
    assert String.starts_with?(cursor, "cursor://anysphere.cursor-deeplink/mcp/install?")
    assert cursor =~ "name=fluxvale&config="
    [encoded] = Regex.run(~r/config=([^&]+)/, cursor, capture: :all_but_first)
    decoded = URI.decode_www_form(encoded)
    payload = Base.decode64!(decoded)
    config = Jason.decode!(payload)
    assert config["url"] == ctx.mcp_url
    assert config["headers"] == %{"Authorization" => "Bearer ${env:FLUXVALE_PAT}"}

    vscode_json = AgentPrompt.install(:vscode, ctx)
    vscode = Jason.decode!(vscode_json)
    assert get_in(vscode, ["servers", "fluxvale", "url"]) == ctx.mcp_url

    assert get_in(vscode, ["servers", "fluxvale", "headers", "Authorization"]) =~
             "FLUXVALE_PAT"

    generic_json = AgentPrompt.install(:generic, ctx)
    generic = Jason.decode!(generic_json)
    assert get_in(generic, ["mcpServers", "fluxvale", "url"]) == ctx.mcp_url

    assert get_in(generic, ["mcpServers", "fluxvale", "headers", "Authorization"]) =~
             "FLUXVALE_PAT"

    for snippet <- [
          claude,
          cursor,
          AgentPrompt.install(:vscode, ctx),
          AgentPrompt.install(:generic, ctx)
        ] do
      refute snippet =~ "fvpat_"
    end
  end

  test "the snippet sentence follows the same auth switch" do
    assert AgentPrompt.snippet_note() =~ "FLUXVALE_PAT"

    previous = Application.get_env(:flux_vale, :mcp_auth_mode)
    on_exit(fn -> Application.put_env(:flux_vale, :mcp_auth_mode, previous) end)
    Application.put_env(:flux_vale, :mcp_auth_mode, :oauth)

    assert AgentPrompt.snippet_note() =~ "browser sign-in"
    refute AgentPrompt.snippet_note() =~ "FLUXVALE_PAT"
  end

  test "the OAuth mode drops the token note and every snippet's header", %{ctx: ctx} do
    previous = Application.get_env(:flux_vale, :mcp_auth_mode)
    on_exit(fn -> Application.put_env(:flux_vale, :mcp_auth_mode, previous) end)
    Application.put_env(:flux_vale, :mcp_auth_mode, :oauth)

    refute AgentPrompt.bearer_headers?()
    assert AgentPrompt.auth_note(ctx) =~ "browser sign-in"
    refute AgentPrompt.auth_note(ctx) =~ "FLUXVALE_PAT"

    claude = AgentPrompt.install(:claude_code, ctx)
    assert claude == "claude mcp add --transport http fluxvale #{ctx.mcp_url}"
    refute claude =~ "--header"

    [encoded] =
      Regex.run(~r/config=([^&]+)/, AgentPrompt.install(:cursor, ctx), capture: :all_but_first)

    decoded = URI.decode_www_form(encoded)
    payload = Base.decode64!(decoded)
    config = Jason.decode!(payload)
    refute Map.has_key?(config, "headers")

    vscode_json = AgentPrompt.install(:vscode, ctx)
    vscode = Jason.decode!(vscode_json)
    refute get_in(vscode, ["servers", "fluxvale", "headers"])
  end

  test "the links are stable absolute URLs on the serving environment", %{ctx: ctx} do
    links = AgentPrompt.links(ctx)

    assert {"Agent setup", ctx.api_base <> "/docs/agents"} in links
    assert {"MCP server", ctx.api_base <> "/docs/automation/mcp"} in links
    assert {"Terraform provider", ctx.api_base <> "/docs/automation/terraform"} in links

    for {_title, url} <- links do
      assert String.starts_with?(url, ctx.api_base <> "/docs/")
    end
  end

  test "the public prompt matches the committed golden fixture" do
    assert File.read!("test/fixtures/agent_prompt.txt") ==
             AgentPrompt.prompt(AgentPrompt.public_context())
  end

  test "llms.txt renders the same prompt plus the link list", %{ctx: ctx} do
    body = AgentPrompt.llms_txt(ctx)

    assert body =~ "# FluxVale"
    assert body =~ AgentPrompt.prompt(ctx)

    for {title, url} <- AgentPrompt.links(ctx) do
      assert body =~ "- [#{title}](#{url})"
    end
  end

  test "the public context leaves the org as a placeholder" do
    ctx = AgentPrompt.public_context()

    assert ctx.org_name == "your organization"
    assert ctx.org_slug == "<your-org-slug>"
    assert ctx.api_base == FluxValeWeb.Endpoint.url()
    assert ctx.mcp_url == Application.fetch_env!(:flux_vale, :mcp_server_url)
    assert AgentPrompt.prompt(ctx) =~ "your organization (<your-org-slug>)"
  end

  test "what it will do names the spend rule" do
    steps = AgentPrompt.what_it_will_do()

    assert "Confirm the spend before deploying" in steps
    assert AgentPrompt.commit_rule() =~ "Confirm the spend"
  end
end
