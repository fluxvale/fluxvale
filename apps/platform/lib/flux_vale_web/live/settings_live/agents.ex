defmodule FluxValeWeb.SettingsLive.Agents do
  @moduledoc """
  The agent quickstart (#484 W5): the remote MCP server's recipe at
  one click from the tokens section — the server URL, the OAuth path
  (add the URL, approve the consent page), the PAT fallback (mint and
  paste, the per-client configs — file snippets for Cursor and
  opencode; Claude Desktop's custom-connector form), the scopes story,
  and the destructive-action gate. The owner ruling: a beta friend with
  zero FluxVale exposure reaches a working agent config in under two
  minutes.

  Documents the REMOTE server (`apps/mcp`, mcp.fluxvale.com) only —
  the platform's own endpoint is a different surface and is not
  referenced here. Static content, no org, no reads: a settings
  section like Developer, reachable from the developer page's tokens
  section link and the account sidebar. The mint link points at the
  developer settings page (#638 moved the tokens panel off
  /settings/access; the page is actor-scoped, so the link serves
  every signed-in actor).

  Tokens are placeholder-only by construction: the snippets carry
  `fvpat_…` and nothing else — the page has no token to echo (the
  mint's one-time reveal stays in the panel).
  """

  use FluxValeWeb, :live_view

  alias FluxValeWeb.AccountSettings
  alias FluxValeWeb.AgentPrompt

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      actor_orgs={@actor_orgs}
      personal_org_id={@personal_org_id}
      username={@username}
      nav_section={@nav_section}
      bare
    >
      <%!-- App-wide grammar page (S10/S11): `bare` main + .appgram —
      the account frame's band (the settings surfaces' shape), the
      sidebar for the way between sections, the page owns its rhythm. --%>
      <div class="appgram contents">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <.link
                navigate={~p"/settings"}
                data-testid="agents-back"
                class="inline-flex items-center gap-1.5 text-sm text-ink-muted transition-colors hover:text-ink"
              >
                <span aria-hidden="true">&larr;</span> Settings
              </.link>
              <div class="mt-3 min-w-0">
                <h1 class="page-title mt-1.5" data-testid="settings-title">
                  Account settings
                </h1>
              </div>
            </div>
          </div>
        </section>

        <section class="wrap pt-8 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <AccountSettings.sidebar
              current="agents"
              personal_org_id={@personal_org_id}
            />

            <div class="min-w-0 flex-1 space-y-6" data-testid="agents-quickstart">
              <div>
                <h2 class="text-base font-medium text-ink" data-testid="agents-title">
                  Use with AI agents
                </h2>
                <p class="mt-1 text-sm text-ink-muted">
                  Give an agent — Claude, Cursor, opencode — your FluxVale account as
                  tools, over MCP: deploy and manage instances, watch the wallet, run
                  backups.
                </p>
                <p class="mt-2 text-sm text-ink-muted">
                  Want the whole first run in one prompt?
                  <.link
                    navigate={~p"/agent"}
                    data-testid="agents-first-run-link"
                    class="font-medium text-ink underline decoration-line underline-offset-2 transition-colors hover:decoration-line-strong"
                  >
                    Finish setup with your agent
                  </.link>
                  — it checks the wallet, proposes an app, and confirms the spend
                  before deploying.
                </p>
              </div>

              <%!-- #766: the no-token path. OAuth-capable clients
              discover the platform from the 401 challenge; the PAT
              snippets below stay the fallback for clients without it. --%>
              <.callout id="agents-oauth" tone="info" data-testid="agents-oauth">
                <p>
                  <span class="font-medium text-ink">OAuth-capable clients need no token.</span>
                  Add the server URL and your client discovers FluxVale's authorization
                  server, registers itself, and opens a consent page — approve once and it
                  connects. The page shows the client name, where it returns, and the
                  scopes in plain language; access spans all your organizations, and
                  disconnecting in
                  <.link
                    navigate={~p"/settings/developer#connected-apps"}
                    class="font-medium text-ink underline decoration-line underline-offset-2 transition-colors hover:decoration-line-strong"
                  >
                    Developer settings
                  </.link>
                  revokes it immediately. The configs below are the fallback for clients
                  without OAuth.
                </p>
              </.callout>

              <%!-- The recipe, numbered like the file-access quick-start
              (the dav snippet's circle idiom): two steps, nothing
              between the mint and a working config. --%>
              <div class="space-y-4" data-testid="agents-recipe">
                <div class="flex gap-3">
                  <span
                    class="flex size-6 shrink-0 items-center justify-center rounded-full border border-line bg-panel text-xs font-medium text-ink-muted"
                    aria-hidden="true"
                  >
                    1
                  </span>
                  <div class="min-w-0">
                    <p class="text-sm font-medium text-ink">Mint a token</p>
                    <p class="mt-1 text-sm text-ink-muted">
                      In the
                      <.link
                        navigate={~p"/settings/developer#api-tokens"}
                        data-testid="agents-tokens-link"
                        class="font-medium text-ink underline decoration-line underline-offset-2 transition-colors hover:decoration-line-strong"
                      >
                        API tokens panel
                      </.link>
                      — name it for the agent, pick its scopes (the MCP domains:
                      catalog, instances, backups, wallet — gateways scopes don't
                      unlock MCP tools today), create it. The full token shows
                      exactly once, there: copy it.
                    </p>
                  </div>
                </div>

                <div class="flex gap-3">
                  <span
                    class="flex size-6 shrink-0 items-center justify-center rounded-full border border-line bg-panel text-xs font-medium text-ink-muted"
                    aria-hidden="true"
                  >
                    2
                  </span>
                  <div class="min-w-0">
                    <p class="text-sm font-medium text-ink">Point your client at the server</p>
                    <p class="mt-1 text-sm text-ink-muted">
                      Paste the server URL and your token into one of the configs below.
                      Claude's form takes the token where
                      <span class="font-mono text-xs">fvpat_…</span>
                      marks; the file snippets read it from
                      <span class="font-mono text-xs">FLUXVALE_PAT</span>
                      in your environment — never a token in a committed file.
                    </p>
                  </div>
                </div>
              </div>

              <%!-- The server URL: the one identifier the recipe hangs
              on, in the sunken mono register with its copy button. --%>
              <div class="mono-panel min-w-0" data-testid="agents-server">
                <span class="mono-panel-label mb-0">FluxVale MCP server</span>
                <div class="mt-3 flex flex-wrap items-center gap-2">
                  <code
                    class="max-w-full overflow-x-auto rounded-control border border-line bg-panel px-2 py-1 text-sm text-ink"
                    data-testid="agents-server-url"
                  >
                    {server_url()}
                  </code>
                  <.copy_button
                    id="copy-agents-server-url"
                    value={server_url()}
                    testid="agents-server-url-copy"
                  />
                </div>
                <%!-- #484 W5: the DNS records ride the beta rollout —
                evergreen wording, no dates, no promises. --%>
                <p class="mt-2 text-xs text-ink-subtle" data-testid="agents-server-dns">
                  If the URL doesn't resolve yet, the endpoint is rolling out — try
                  again shortly.
                </p>
              </div>

              <%!-- The per-client configs. Claude Desktop's remote
              path is a connector FORM, not a file —
              claude_desktop_config.json is the local-stdio mechanism,
              and the auth choice is explicitly No sign-in (the
              bearer header IS the auth). Cursor rides the mcpServers
              grammar in a file; opencode nests under mcp.servers
              (the V2 shape — direct-under-mcp entries are silently
              dropped; v1 uses a different layout — upgrade rather
              than hand-edit) with protocol auto (the legacy default
              caps at 2025-11-25; the destructive tools'
              confirmations need the 2026-07-28 stateless revision)
              and oauth off in this fallback (the snippet sends the PAT
              header; OAuth-capable clients use the callout's flow
              instead). The file snippets reference the
              token through each client's env syntax — never a
              committable PAT (CodeRabbit GNsI). --%>
              <div class="space-y-6" data-testid="agents-clients">
                <p class="text-xs text-ink-subtle" data-testid="agents-clients-secret">
                  Never commit a token: both snippets read it from
                  <span class="font-mono">FLUXVALE_PAT</span>
                  in your environment (Cursor <span class="font-mono">{"${env:FLUXVALE_PAT}"}</span>, opencode <span class="font-mono">{"{env:FLUXVALE_PAT}"}</span>) — the file
                  stays shareable.
                </p>

                <div class="space-y-2" data-testid="agents-config-claude">
                  <div class="flex flex-wrap items-baseline justify-between gap-2">
                    <h3 class="text-sm font-medium text-ink">Claude Desktop</h3>
                    <span class="text-xs text-ink-subtle">
                      Customize → Connectors → Add custom connector
                    </span>
                  </div>
                  <p class="text-xs text-ink-subtle">
                    No config file — a remote server is a custom connector
                    (<span class="font-mono">claude_desktop_config.json</span> is the
                    local-stdio mechanism).
                  </p>
                  <div class="mono-panel min-w-0">
                    <span class="mono-panel-label mb-0">connector</span>
                    <ol
                      class="mt-3 list-inside list-decimal space-y-2 text-xs leading-relaxed text-ink"
                      data-testid="agents-config-claude-steps"
                    >
                      <li>Name it <span class="font-medium">FluxVale</span>.</li>
                      <li>URL: <span class="font-mono">{server_url()}</span></li>
                      <li>
                        Auth: pick <span class="font-medium">No sign-in</span>
                        (not OAuth — the header below is the auth).
                      </li>
                      <li>
                        Request headers: <code class="font-mono">Authorization: Bearer fvpat_…</code>
                        <.copy_button
                          id="copy-agents-config-claude"
                          value={claude_header_value()}
                          testid="agents-config-claude-copy"
                        />
                      </li>
                    </ol>
                  </div>
                </div>

                <div class="space-y-2" data-testid="agents-config-cursor">
                  <div class="flex flex-wrap items-baseline justify-between gap-2">
                    <h3 class="text-sm font-medium text-ink">Cursor</h3>
                    <code class="font-mono text-xs text-ink-subtle">.cursor/mcp.json</code>
                  </div>
                  <p class="text-xs text-ink-subtle">
                    Project scope at <span class="font-mono">.cursor/mcp.json</span>,
                    global at <span class="font-mono">~/.cursor/mcp.json</span>. Same
                    shape either way — the token rides
                    <span class="font-mono">{"${env:FLUXVALE_PAT}"}</span>
                    (set it in your shell), never the file.
                  </p>
                  <div class="mono-panel min-w-0">
                    <div class="flex flex-wrap items-center justify-between gap-2">
                      <span class="mono-panel-label mb-0">config</span>
                      <.copy_button
                        id="copy-agents-config-cursor"
                        value={cursor_config()}
                        testid="agents-config-cursor-copy"
                      />
                    </div>
                    <pre
                      class="mt-3 overflow-x-auto rounded-control bg-panel-raised p-3 text-xs leading-relaxed text-ink"
                      phx-no-curly-interpolation
                    ><code><%= cursor_config() %></code></pre>
                  </div>
                </div>

                <div class="space-y-2" data-testid="agents-config-opencode">
                  <div class="flex flex-wrap items-baseline justify-between gap-2">
                    <h3 class="text-sm font-medium text-ink">opencode</h3>
                    <code class="font-mono text-xs text-ink-subtle">opencode.json</code>
                  </div>
                  <p class="text-xs text-ink-subtle">
                    Requires opencode v2 (the <span class="font-mono">mcp.servers</span>
                    shape) — v1 uses a different layout; upgrade rather than hand-edit.
                    Project scope at <span class="font-mono">opencode.json</span>, global
                    at <span class="font-mono">~/.config/opencode/opencode.json</span>.
                    The token rides <span class="font-mono">{"{env:FLUXVALE_PAT}"}</span>
                    (set it in your shell), never the file.
                  </p>
                  <div class="mono-panel min-w-0">
                    <div class="flex flex-wrap items-center justify-between gap-2">
                      <span class="mono-panel-label mb-0">config</span>
                      <.copy_button
                        id="copy-agents-config-opencode"
                        value={opencode_config()}
                        testid="agents-config-opencode-copy"
                      />
                    </div>
                    <pre
                      class="mt-3 overflow-x-auto rounded-control bg-panel-raised p-3 text-xs leading-relaxed text-ink"
                      phx-no-curly-interpolation
                    ><code><%= opencode_config() %></code></pre>
                  </div>
                </div>
              </div>

              <%!-- The scopes story: the token's scope list IS the
              agent's reach (tools/list offers exactly what it covers),
              and the panel is where both the minting and the meanings
              live. --%>
              <.callout id="agents-scopes" tone="info" data-testid="agents-scopes">
                <p>
                  <span class="font-medium text-ink">What the agent can do is what the
                  token allows.</span>
                  The server offers exactly the tools the token's scopes cover — write
                  includes read, so an instances:write token sees every instances tool.
                  Some tools need two domains — deploy reads the catalog before it
                  writes the instance — so mint the union; the docs/mcp.md catalog
                  table lists each tool's exact set. A zero-scope token still
                  identifies itself. The scope meanings are
                  listed where you mint,
                  <.link
                    navigate={~p"/settings/developer#api-tokens"}
                    class="font-medium text-ink underline decoration-line underline-offset-2 transition-colors hover:decoration-line-strong"
                  >
                    in the API tokens panel
                  </.link>
                  .
                </p>
              </.callout>

              <%!-- The destructive gate, from the server's own posture
              (apps/mcp): ask first; a client that cannot confirm gets
              an honest error and nothing changes. --%>
              <.callout id="agents-destructive" tone="warning" data-testid="agents-destructive">
                <p>
                  <span class="font-medium text-ink">Destructive actions ask first.</span>
                  Destroying an instance and restoring a backup confirm through your
                  client before anything runs. A client that can't show that
                  confirmation gets a clear error and nothing changes — do those from
                  the panel instead.
                </p>
              </.callout>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # The snippets are page constants on purpose: one server, one
  # placeholder, no per-visitor interpolation — the placeholder rule
  # holds by construction, not by filtering.

  # The configured endpoint (prod, staging, or the local k3d host) —
  # the same source the agent handoff renders (#765).
  defp server_url, do: AgentPrompt.mcp_url()

  defp claude_header_value, do: "Authorization: Bearer fvpat_…"

  defp cursor_config do
    """
    {
      "mcpServers": {
        "fluxvale": {
          "url": "#{server_url()}",
          "headers": {
            "Authorization": "Bearer ${env:FLUXVALE_PAT}"
          }
        }
      }
    }
    """
  end

  defp opencode_config do
    """
    {
      "$schema": "https://opencode.ai/config.json",
      "mcp": {
        "servers": {
          "fluxvale": {
            "type": "remote",
            "protocol": "auto",
            "url": "#{server_url()}",
            "oauth": false,
            "headers": {
              "Authorization": "Bearer {env:FLUXVALE_PAT}"
            }
          }
        }
      }
    }
    """
  end
end
