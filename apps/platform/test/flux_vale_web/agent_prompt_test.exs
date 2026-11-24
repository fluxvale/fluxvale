defmodule FluxValeWeb.AgentPromptTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias FluxValeWeb.AgentPrompt
  alias FluxValeWeb.BillingComponents

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

  test "the prompt asks once about single sign-on and walks the paid-org branch", %{ctx: ctx} do
    prompt = AgentPrompt.prompt(ctx)

    assert prompt =~ "Ask me once whether I want single sign-on (OIDC) for my apps."
    assert prompt =~ "If I say no, accept it and never ask again this session."
    assert prompt =~ "SSO is a paid-org feature and welcome credit alone does not unlock it"
    assert prompt =~ "`wallet_ledger`"
    assert prompt =~ "`wallet_balance`"
    assert prompt =~ "`paywall_waived`"
    assert prompt =~ "wait while I complete checkout in my browser. Never ask for card details."
    assert prompt =~ "`pocket-id`"
    assert prompt =~ "`apps_show`"
    assert prompt =~ "`ENCRYPTION_KEY`"
    assert prompt =~ "`instances_deploy`"
    assert prompt =~ BillingComponents.topup_ladder_choices()
    assert prompt =~ BillingComponents.topup_ladder_top()
    assert prompt =~ ctx.api_base <> "/billing/topup"
    assert prompt =~ ctx.api_base <> "/docs/guides/sso"
  end

  test "the SSO ask appears exactly once in the prompt", %{ctx: ctx} do
    prompt = AgentPrompt.prompt(ctx)
    ask = "Ask me once whether I want single sign-on (OIDC) for my apps."
    parts = String.split(prompt, ask)

    assert length(parts) == 2
  end

  test "the prompt numbers its steps 1 through 9 with no gap or repeat", %{ctx: ctx} do
    prompt = AgentPrompt.prompt(ctx)
    matches = Regex.scan(~r/^(\d+)\. /m, prompt, capture: :all_but_first)

    assert List.flatten(matches) == Enum.map(1..9, &Integer.to_string/1)
  end

  test "the new SSO step holds no em-dash and no semicolon", %{ctx: ctx} do
    prompt = AgentPrompt.prompt(ctx)
    before_parts = String.split(prompt, "4. Confirm the spend")
    before_step4 = List.first(before_parts)
    step_parts = String.split(before_step4, "3. ")
    new_step = List.last(step_parts)

    assert String.starts_with?(new_step, "Ask me once whether I want single sign-on")
    refute new_step =~ "—"
    refute new_step =~ ";"
  end

  test "the auth sentence is the PAT path, with no second OAuth path", %{ctx: ctx} do
    note = AgentPrompt.auth_note(ctx)

    assert note =~ "#{ctx.api_base}/settings/developer#api-tokens"
    assert note =~ "FLUXVALE_PAT"
    assert note =~ "Authorization: Bearer $FLUXVALE_PAT"
    refute note =~ "OAuth"
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
    refute Map.has_key?(config, "type")

    vscode_json = AgentPrompt.install(:vscode, ctx)
    vscode = Jason.decode!(vscode_json)
    assert get_in(vscode, ["mcpServers", "fluxvale", "url"]) == ctx.mcp_url

    assert get_in(vscode, ["mcpServers", "fluxvale", "headers", "Authorization"]) ==
             "Bearer ${FLUXVALE_PAT}"

    refute vscode_json =~ "${env:"

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

  test "the client cards pair each install key with its rendered snippet", %{ctx: ctx} do
    cards = AgentPrompt.clients_with_code(ctx)

    assert Enum.map(cards, & &1.key) == ["claude-code", "cursor", "vscode", "generic"]

    for card <- cards do
      assert card.code == AgentPrompt.install(card.install, ctx)
      refute card.code =~ "fvpat_"
    end

    # The helper reads the auth switch at call time, not module load.
    previous = Application.get_env(:flux_vale, :mcp_auth_mode)
    on_exit(fn -> Application.put_env(:flux_vale, :mcp_auth_mode, previous) end)
    Application.put_env(:flux_vale, :mcp_auth_mode, :oauth)

    oauth_cards = AgentPrompt.clients_with_code(ctx)
    headers? = Enum.any?(oauth_cards, &(&1.code =~ "--header"))
    refute headers?
  end

  test "the snippet sentence follows the same auth switch" do
    assert AgentPrompt.snippet_note() =~ "FLUXVALE_PAT"

    previous = Application.get_env(:flux_vale, :mcp_auth_mode)
    on_exit(fn -> Application.put_env(:flux_vale, :mcp_auth_mode, previous) end)
    Application.put_env(:flux_vale, :mcp_auth_mode, :oauth)

    assert AgentPrompt.snippet_note() =~ "browser sign-in"
    refute AgentPrompt.snippet_note() =~ "FLUXVALE_PAT"
  end

  test "the OAuth mode keeps the PAT fallback and drops every snippet's header", %{ctx: ctx} do
    previous = Application.get_env(:flux_vale, :mcp_auth_mode)
    on_exit(fn -> Application.put_env(:flux_vale, :mcp_auth_mode, previous) end)
    Application.put_env(:flux_vale, :mcp_auth_mode, :oauth)

    refute AgentPrompt.bearer_headers?()
    assert AgentPrompt.auth_note(ctx) =~ "browser sign-in"
    assert AgentPrompt.auth_note(ctx) =~ "FLUXVALE_PAT"
    assert AgentPrompt.auth_note(ctx) =~ "Authorization: Bearer $FLUXVALE_PAT"

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
    refute get_in(vscode, ["mcpServers", "fluxvale", "headers"])
  end

  test "the vscode and generic snippets share one entry, apart from the env syntax", %{ctx: ctx} do
    vscode_json = AgentPrompt.install(:vscode, ctx)
    vscode = Jason.decode!(vscode_json)

    generic_json = AgentPrompt.install(:generic, ctx)
    generic = Jason.decode!(generic_json)

    assert get_in(vscode, ["mcpServers", "fluxvale", "headers", "Authorization"]) ==
             "Bearer ${FLUXVALE_PAT}"

    assert get_in(generic, ["mcpServers", "fluxvale", "headers", "Authorization"]) ==
             "Bearer ${env:FLUXVALE_PAT}"

    vscode_entry = get_in(vscode, ["mcpServers", "fluxvale"])
    generic_entry = get_in(generic, ["mcpServers", "fluxvale"])

    assert Map.delete(vscode_entry, "headers") == Map.delete(generic_entry, "headers")

    previous = Application.get_env(:flux_vale, :mcp_auth_mode)
    on_exit(fn -> Application.put_env(:flux_vale, :mcp_auth_mode, previous) end)
    Application.put_env(:flux_vale, :mcp_auth_mode, :oauth)

    assert AgentPrompt.install(:vscode, ctx) == AgentPrompt.install(:generic, ctx)
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

  test "the links carry the SSO guide", %{ctx: ctx} do
    assert {"SSO with Pocket ID", ctx.api_base <> "/docs/guides/sso"} in AgentPrompt.links(ctx)
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

  test "what it will do lists the SSO ask in its order" do
    assert AgentPrompt.what_it_will_do() == [
             "Check your wallet and stop at zero",
             "Propose an app with its size and monthly price",
             "Ask once if you want SSO with Pocket ID (optional, paid org)",
             "Confirm the spend before deploying",
             "Deploy and set env vars",
             "Verify the instance URL",
             "Ask before anything destructive"
           ]
  end

  test "the remote CLI bridge note appears in auth_note under both :pat and :oauth", %{ctx: ctx} do
    expected =
      "On a machine without a browser, sign in with `fluxvale mcp login` and connect the client through `fluxvale mcp serve`."

    previous = Application.get_env(:flux_vale, :mcp_auth_mode)
    on_exit(fn -> Application.put_env(:flux_vale, :mcp_auth_mode, previous) end)

    # The join matters too: the note follows the auth sentence with exactly one space.
    joined = "on the MCP connection. " <> expected

    Application.put_env(:flux_vale, :mcp_auth_mode, :pat)
    assert AgentPrompt.auth_note(ctx) =~ expected
    assert AgentPrompt.auth_note(ctx) =~ joined

    Application.put_env(:flux_vale, :mcp_auth_mode, :oauth)
    assert AgentPrompt.auth_note(ctx) =~ expected
    assert AgentPrompt.auth_note(ctx) =~ joined
  end

  test "prompt/1 and llms_txt/1 carry the remote CLI bridge note", %{ctx: ctx} do
    expected =
      "On a machine without a browser, sign in with `fluxvale mcp login` and connect the client through `fluxvale mcp serve`."

    assert AgentPrompt.prompt(ctx) =~ expected
    assert AgentPrompt.llms_txt(ctx) =~ expected
  end
end
