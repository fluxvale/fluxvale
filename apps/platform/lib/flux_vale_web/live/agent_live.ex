defmodule FluxValeWeb.AgentLive do
  @moduledoc """
  The post-registration handoff (#765): "Finish setup with your agent".
  A fresh invitee lands here after accepting, and the route stays
  reachable at `/agent` for anyone who wants the prompt later.

  Everything the page renders comes from `FluxValeWeb.AgentPrompt` —
  the generated prompt (org + API base + MCP URL), the four client
  install snippets, and the "what it will do" list — rendered through
  the shared `FluxValeWeb.AgentPanel` body. The page holds no token:
  snippets reference `FLUXVALE_PAT` by name only.

  "I'll explore myself" leaves for the dashboard. The invite flow only
  redirects here once, so a dismissal needs no stored flag.
  """

  use FluxValeWeb, :live_view

  alias FluxValeWeb.AgentPanel
  alias FluxValeWeb.AgentPrompt

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    org = AgentPanel.org_from_assigns(socket.assigns)
    ctx = AgentPrompt.context(org && org.name, org && org.slug)

    snippets = AgentPrompt.clients_with_code(ctx)

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

        <AgentPanel.body
          prompt={@prompt}
          snippets={@snippets}
          snippet_note={@snippet_note}
          what_it_will_do={@what_it_will_do}
        >
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
        </AgentPanel.body>
      </div>
    </Layouts.app>
    """
  end
end
