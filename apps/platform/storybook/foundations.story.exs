defmodule FluxValeWeb.Storybook.Foundations do
  @moduledoc """
  Design foundations (#178): the amber ramp, semantic tokens, and
  typography. The tokens live in `assets/css/app.css`; this page is
  their living reference.
  """

  use PhoenixStorybook.Story, :page

  def doc do
    "The FluxVale design system on v1's heritage amber. Primary actions and brand moments are amber; everything else is a warm neutral (stone) in light mode, slate in dark. Inter for text."
  end

  @ramp [
    {"50", "bg-brand-50"},
    {"100", "bg-brand-100"},
    {"200", "bg-brand-200"},
    {"300", "bg-brand-300"},
    {"400", "bg-brand-400"},
    {"500", "bg-brand-500"},
    {"600", "bg-brand-600"},
    {"700", "bg-brand-700"},
    {"800", "bg-brand-800"},
    {"900", "bg-brand-900"}
  ]

  @semantic [
    {"primary (action)", "bg-primary"},
    {"primary-muted (wash)", "bg-primary-muted"},
    {"canvas (page)", "bg-canvas border border-line"},
    {"panel (card)", "bg-panel border border-line"},
    {"panel-raised (hover)", "bg-panel-raised border border-line"}
  ]

  @text [
    {"ink (primary text)", "text-ink"},
    {"ink-muted (secondary)", "text-ink-muted"},
    {"ink-subtle (tertiary)", "text-ink-subtle"}
  ]

  @state [
    {"success", "bg-success-muted text-success border border-line-success"},
    {"warning", "bg-warning-muted text-warning border border-line-warning"},
    {"danger", "bg-danger-muted text-danger border border-line-danger"}
  ]

  def render(assigns) do
    # Module attributes aren't reachable from HEEx (@x reads assigns.x
    # there) — bind the token tables into assigns first.
    assigns =
      assign(assigns,
        ramp: @ramp,
        semantic: @semantic,
        text: @text,
        state: @state
      )

    ~H"""
    <div class="space-y-10 pb-10">
      <section class="space-y-3" aria-labelledby="foundations-ramp">
        <h2 id="foundations-ramp" class="text-lg font-semibold text-ink">Brand ramp</h2>
        <p class="text-sm text-ink-muted">
          FluxVale amber (v1 heritage ramp, OKLCH hue ~55). Static in both modes — components pick
          the shade via semantic tokens.
        </p>
        <div class="flex overflow-hidden rounded-xl border border-line">
          <div
            :for={{step, class} <- @ramp}
            class={["flex-1 pt-16 pb-2 text-center text-[10px] font-medium", class]}
            data-testid={"ramp-#{step}"}
          >
            {step}
          </div>
        </div>
      </section>

      <section class="space-y-3" aria-labelledby="foundations-semantic">
        <h2 id="foundations-semantic" class="text-lg font-semibold text-ink">Semantic tokens</h2>
        <p class="text-sm text-ink-muted">
          What components actually use. Each flips with the color mode (the toggle in the header).
        </p>
        <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          <div
            :for={{name, class} <- @semantic}
            class={["rounded-lg px-4 py-3 text-sm font-medium", class]}
          >
            {name}
          </div>
        </div>
      </section>

      <section class="space-y-3" aria-labelledby="foundations-text">
        <h2 id="foundations-text" class="text-lg font-semibold text-ink">Text</h2>
        <div class="space-y-1 rounded-xl border border-line bg-panel p-4">
          <p :for={{name, class} <- @text} class={["text-sm", class]}>{name}</p>
        </div>
      </section>

      <section class="space-y-3" aria-labelledby="foundations-state">
        <h2 id="foundations-state" class="text-lg font-semibold text-ink">State colors</h2>
        <div class="grid gap-2 sm:grid-cols-3">
          <div
            :for={{name, class} <- @state}
            class={["rounded-lg px-4 py-3 text-sm font-medium", class]}
          >
            {name}
          </div>
        </div>
      </section>

      <section class="space-y-3" aria-labelledby="foundations-type">
        <h2 id="foundations-type" class="text-lg font-semibold text-ink">Typography</h2>
        <div class="space-y-3 rounded-xl border border-line bg-panel p-5">
          <p class="text-3xl font-bold tracking-tight text-ink">Deploy in minutes — text-3xl bold</p>
          <p class="text-2xl font-semibold tracking-tight text-ink">Page title — text-2xl semibold</p>
          <p class="text-base font-medium text-ink">Card title — text-base medium</p>
          <p class="text-sm text-ink-muted">Body copy — text-sm, muted for secondary lines.</p>
          <p class="font-mono text-xs text-ink-muted">font-mono text-xs — slugs, versions, amounts</p>
        </div>
      </section>
    </div>
    """
  end
end
