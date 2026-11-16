defmodule FluxValeWeb.AgentPanel do
  @moduledoc """
  The agent handoff panel (#817): the "1. Copy the prompt" block, the
  client install snippets, the what-it-will-do list, and the spend
  rule — extracted verbatim from `AgentLive` so a second surface (the
  onboarding modal) renders the identical body. The hero band and the
  dismissal stay `/agent`'s: the dismissal is page-specific, so it
  rides the inner slot and the modal omits it.

  The body owns markup only: copy still flows from
  `FluxValeWeb.AgentPrompt` via the caller's assigns, and no token
  ever passes through it — snippets reference `FLUXVALE_PAT` by name
  only. The module's one data helper is `org_from_assigns/1`: the org
  the prompt names, resolved from OrgNav's assigns.
  """

  use FluxValeWeb, :html

  @doc """
  The panel body: the two-column grid — the prompt block and the
  client snippets left, the what-it-will-do card and the spend rule
  right. The inner slot splices the caller's page-specific tail after
  the callout in the aside; an omitted slot renders nothing.
  """
  attr(:prompt, :string, required: true, doc: "the generated prompt (AgentPrompt.prompt/1)")

  attr(:snippets, :list,
    required: true,
    doc: "the client cards with rendered install code (AgentPrompt.clients_with_code/1)"
  )

  attr(:snippet_note, :string,
    required: true,
    doc: "the auth note above the snippets (AgentPrompt.snippet_note/0)"
  )

  attr(:what_it_will_do, :list,
    required: true,
    doc: "the ordered promise list (AgentPrompt.what_it_will_do/0)"
  )

  slot(:inner_block,
    doc: "the aside's page-specific tail — /agent's \"I'll explore myself\" card"
  )

  @spec body(map()) :: Phoenix.LiveView.Rendered.t()
  def body(assigns) do
    ~H"""
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

          {render_slot(@inner_block)}
        </aside>
      </div>
    </section>
    """
  end

  # The prompt names the personal org — the first-run target, and the
  # org the dashboard's wallet resolves for a new account.
  @spec org_from_assigns(map()) :: FluxVale.Accounts.Organization.t() | nil
  def org_from_assigns(assigns) do
    orgs = assigns.actor_orgs
    personal_id = assigns.personal_org_id

    case Enum.find(orgs, &(&1.organization.id == personal_id)) || List.first(orgs) do
      nil -> nil
      membership -> membership.organization
    end
  end
end
