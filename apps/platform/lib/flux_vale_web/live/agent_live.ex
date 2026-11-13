defmodule FluxValeWeb.AgentLive do
  @moduledoc """
  The post-registration handoff (#765): "Finish setup with your agent".
  A fresh invitee lands here after accepting, and the route stays
  reachable at `/agent` for anyone who wants the prompt later.

  Everything the page renders comes from `FluxValeWeb.AgentPrompt` —
  the generated prompt (org + API base + MCP URL), the four client
  install snippets, and the "what it will do" list. The page holds no
  token: snippets reference `FLUXVALE_PAT` by name only.

  "I'll explore myself" leaves for the dashboard. The invite flow only
  redirects here once, so a dismissal needs no stored flag.
  """

  use FluxValeWeb, :live_view

  alias FluxValeWeb.AgentPrompt

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    org = personal_org(socket.assigns)
    ctx = AgentPrompt.context(org && org.name, org && org.slug)

    snippets =
      Enum.map(AgentPrompt.clients(), fn client ->
        Map.put(client, :code, AgentPrompt.install(client.install, ctx))
      end)

    {:ok,
     socket
     |> assign(:page_title, "Finish setup with your agent · FluxVale")
     |> assign(:ctx, ctx)
     |> assign(:prompt, AgentPrompt.prompt(ctx))
     |> assign(:snippets, snippets)
     |> assign(:what_it_will_do, AgentPrompt.what_it_will_do())
     |> assign(:commit_rule, AgentPrompt.commit_rule())
     |> assign(:snippet_note, AgentPrompt.snippet_note())}
  end

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
      <div class="appgram contents" data-testid="agent-panel">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">Your first run</p>
              <h1 class="page-title mt-1.5">Finish setup with your agent</h1>
              <p class="mt-2 max-w-2xl text-base text-ink-muted">
                Copy one prompt into the agent you already use. It connects to
                FluxVale, proposes an app, and deploys it — checking the wallet
                and confirming the spend with you first.
              </p>
            </div>
          </div>
        </section>

        <section class="wrap pt-10 pb-16">
          <div class="rise grid gap-8 lg:grid-cols-[minmax(0,1fr)_20rem]">
            <div class="min-w-0 space-y-8">
              <div class="space-y-4">
                <div class="flex flex-wrap items-end justify-between gap-3">
                  <div class="min-w-0">
                    <h2 class="text-base font-medium text-ink">1. Copy the prompt</h2>
                    <p class="mt-1 text-sm text-ink-muted">
                      It already names your organization, the API base, and the MCP
                      server — paste it as-is.
                    </p>
                  </div>
                  <.copy_button
                    id="copy-agent-prompt"
                    value={@prompt}
                    label="Copy prompt"
                    testid="agent-prompt-copy"
                  />
                </div>

                <div class="mono-panel min-w-0">
                  <span class="mono-panel-label mb-0">prompt</span>
                  <pre
                    class="mt-3 whitespace-pre-wrap break-words rounded-control bg-panel-raised p-4 text-xs leading-relaxed text-ink"
                    data-testid="agent-prompt"
                    phx-no-curly-interpolation
                  ><code><%= @prompt %></code></pre>
                </div>
              </div>

              <div class="space-y-4" data-testid="agent-clients">
                <div>
                  <h2 class="text-base font-medium text-ink">2. Connect a client</h2>
                  <p class="mt-1 text-sm text-ink-muted" data-testid="agent-snippet-note">
                    {@snippet_note}
                  </p>
                </div>

                <div class="grid gap-4 sm:grid-cols-2">
                  <div
                    :for={client <- @snippets}
                    class="min-w-0 rounded-panel border border-line bg-panel p-5"
                    data-testid={"agent-client-#{client.key}"}
                  >
                    <div class="flex flex-wrap items-baseline justify-between gap-2">
                      <h3 class="text-sm font-medium text-ink">{client.title}</h3>
                      <.copy_button
                        id={"copy-agent-client-#{client.key}"}
                        value={client.code}
                        testid={"agent-client-#{client.key}-copy"}
                      />
                    </div>
                    <p class="mt-1 text-xs text-ink-subtle">{client.hint}</p>
                    <pre
                      class={[
                        "mt-3 max-h-48 overflow-auto whitespace-pre-wrap rounded-control bg-panel-raised p-3 text-xs leading-relaxed text-ink",
                        client.wrap
                      ]}
                      data-testid={"agent-client-#{client.key}-code"}
                      phx-no-curly-interpolation
                    ><code><%= client.code %></code></pre>
                  </div>
                </div>
              </div>
            </div>

            <aside class="min-w-0 space-y-6">
              <div class="rounded-panel border border-line bg-panel p-6">
                <h2 class="text-sm font-medium text-ink">What it will do</h2>
                <ol class="mt-4 space-y-3" data-testid="agent-what-it-will-do">
                  <li
                    :for={{step, index} <- Enum.with_index(@what_it_will_do)}
                    class="flex gap-3 text-sm text-ink-muted"
                  >
                    <span
                      class="mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-full border border-line bg-panel-raised font-mono text-[10px] text-ink-subtle"
                      aria-hidden="true"
                    >
                      {index + 1}
                    </span>
                    <span>{step}</span>
                  </li>
                </ol>
              </div>

              <.callout id="agent-spend-rule" tone="warning" data-testid="agent-spend-rule">
                <p>
                  <span class="font-medium text-ink">It asks before it spends.</span>
                  The agent proposes an app and its monthly price (billed hourly),
                  then waits for your yes. An empty wallet stops the run with the top-up link — it never
                  deploys on credit.
                </p>
              </.callout>

              <div class="rounded-panel border border-line bg-panel p-6">
                <p class="text-sm text-ink-muted">
                  Prefer to look around first? The panel is always here at <span class="font-mono text-xs">/agent</span>.
                </p>
                <.button
                  navigate={~p"/"}
                  variant="secondary"
                  class="mt-4 w-full"
                  data-testid="agent-dismiss"
                >
                  I'll explore myself
                </.button>
              </div>
            </aside>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # The prompt names the personal org — the first-run target, and the
  # org the dashboard's wallet resolves for a new account.
  defp personal_org(assigns) do
    orgs = assigns.actor_orgs
    personal_id = assigns.personal_org_id

    case Enum.find(orgs, &(&1.organization.id == personal_id)) || List.first(orgs) do
      nil -> nil
      membership -> membership.organization
    end
  end
end
