defmodule FluxValeWeb.Storybook.Foundations do
  @moduledoc """
  Design foundations (#178): the amber ramp, semantic tokens, the
  olive info accent, elevation, radius, and motion. The tokens live in
  `assets/css/app.css` (mirrored in `storybook.css`); this page is
  their living reference. Grove refresh (#277).
  """

  use PhoenixStorybook.Story, :page

  import FluxValeWeb.CoreComponents, only: [icon: 1]

  def doc do
    "Direction C — Grove (#277): amber stays the action colour (bright fill, dark ink — never white-on-amber), an olive accent carries information, and surfaces are warm sand (light) and warm brown-black (dark). Success leans teal to hold ≥40° hue from olive. Status is never colour-alone: icon and label always pair."
  end

  # Strip labels: dark ink on the light steps (brand-900 in dark mode,
  # where page ink flips light), light brand-50 on the dark steps.
  # brand-600 is the one step no token inks at 4.5 (white 4.18:1, ink
  # 4.10:1, brand-50 3.82:1) — #000 is the only 4.5+ label there (5.02).
  @ramp [
    {"50", "bg-brand-50", "text-ink dark:text-brand-900"},
    {"100", "bg-brand-100", "text-ink dark:text-brand-900"},
    {"200", "bg-brand-200", "text-ink dark:text-brand-900"},
    {"300", "bg-brand-300", "text-ink dark:text-brand-900"},
    {"400", "bg-brand-400", "text-ink dark:text-brand-900"},
    {"500", "bg-brand-500", "text-ink dark:text-brand-900"},
    {"600", "bg-brand-600", "text-black"},
    {"700", "bg-brand-700", "text-brand-50"},
    {"800", "bg-brand-800", "text-brand-50"},
    {"900", "bg-brand-900", "text-brand-50"}
  ]

  @semantic [
    {"primary (action)", "bg-primary"},
    {"primary-muted (wash)", "bg-primary-muted"},
    {"canvas (page)", "bg-canvas border border-line"},
    {"panel (card)", "bg-panel border border-line"},
    {"panel-raised (hover)", "bg-panel-raised border border-line"}
  ]

  @surface_tokens [
    {"--canvas", "#fbf8f3", "#17130f"},
    {"--panel", "#fffdfa", "#221c16"},
    {"--panel-raised", "#f5efe5", "#322a21"},
    {"--line", "#eae0d1", "#322a21"},
    {"--ink", "#221a12", "#f5ece1"},
    {"--ink-muted", "#514639", "#c2b3a1"},
    {"--ink-subtle", "#655f58", "#a29484"}
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

  @info_tokens [
    {"--info (text)", "#515c0a", "#bcd874"},
    {"--info-muted (tint)", "#eaeadd", "#343321"},
    {"--border-info (tint edge)", "#b6b995", "#505432"}
  ]

  @success_tokens [
    {"--success (text)", "#007b65", "oklch(75% 0.13 184) ≈ #17c8b7"},
    {"--success-muted (tint)", "#e7faf4", "oklch(75% 0.13 184 / 18%)"},
    {"--border-success (tint edge)", "#8aceba", "oklch(75% 0.13 184 / 30%)"},
    # --warning (dark retuned): hue 84° → 78° (chroma nudged to stay in
    # sRGB gamut) so the olive accent keeps >= 40° of hue from BOTH
    # neighbours; the authored value renders exactly (#ffbc46).
    {"--warning", "#d97706 · 59° from olive",
     "oklch(83.69% 0.15 78) ≈ #ffbc46 · 44° (was #fbbf24 · 38°)"}
  ]

  @elevation [
    {"shadow-xs", "0 1px 2px 0 rgb(38 43 43 / 5%)", "shadow-xs"},
    {"shadow-sm", "0 2px 4px -1px rgb(38 43 43 / 12%)", "shadow-sm"},
    {"shadow-md", "0 2px 8px -2px rgb(38 43 43 / 20%)", "shadow-md"},
    {"shadow-lg", "0 10px 15px -3px rgb(38 43 43 / 10%), 0 4px 6px -4px rgb(38 43 43 / 10%)",
     "shadow-lg"}
  ]

  @radius [
    {"rounded-panel", "--radius-panel · 0.75rem", "Panels and cards — soft (xl-class)"},
    {"rounded-control", "--radius-control · 0.5rem", "Buttons and inputs — crisp (lg-class)"},
    {"rounded-pill", "--radius-pill · 9999px", "Pills and avatars — full"}
  ]

  @motion [
    {"--motion-fast", "150ms"},
    {"--motion-base", "200ms"},
    {"--motion-slow", "300ms"},
    {"--motion-ease-out", "cubic-bezier(0, 0, 0.2, 1)"}
  ]

  def render(assigns) do
    # Module attributes aren't reachable from HEEx (@x reads assigns.x
    # there) — bind the token tables into assigns first.
    assigns =
      assign(assigns,
        ramp: @ramp,
        semantic: @semantic,
        surface_tokens: @surface_tokens,
        text: @text,
        state: @state,
        info_tokens: @info_tokens,
        success_tokens: @success_tokens,
        elevation: @elevation,
        radius: @radius,
        motion: @motion
      )

    ~H"""
    <div class="space-y-10 pb-10">
      <section class="space-y-3" aria-labelledby="foundations-ramp">
        <h2 id="foundations-ramp" class="text-lg font-semibold text-ink">Brand ramp</h2>
        <p class="text-sm text-ink-muted">
          FluxVale amber (v1 heritage ramp, OKLCH hue ~55). Static in both modes — components pick
          the shade via semantic tokens. Steps 100/200/300/600/700 were re-authored at the sRGB
          gamut boundary in #277 (same L and H, chroma pulled in ≤0.012), so rendering matches
          authoring:
          <span class="font-mono text-xs">#ffebd6 · #ffd5ae · #ffba81 · #c85d02 · #a74900</span>
        </p>
        <div class="flex overflow-hidden rounded-xl border border-line">
          <div
            :for={{step, bg_class, label_class} <- @ramp}
            class={["flex-1 pt-16 pb-2 text-center text-[10px] font-medium", bg_class, label_class]}
            data-testid={"ramp-#{step}"}
          >
            {step}
          </div>
        </div>
      </section>

      <section class="space-y-3" aria-labelledby="foundations-semantic">
        <h2 id="foundations-semantic" class="text-lg font-semibold text-ink">Semantic tokens</h2>
        <p class="text-sm text-ink-muted">
          What components actually use. Grove surfaces: warm sand in light mode, warm brown-black in
          dark. Each flips with the color mode (the toggle in the header).
        </p>
        <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          <div
            :for={{name, class} <- @semantic}
            class={["rounded-lg px-4 py-3 text-sm font-medium", class]}
          >
            {name}
          </div>
        </div>
        <div class="overflow-hidden rounded-xl border border-line bg-panel">
          <table class="w-full text-left font-mono text-xs">
            <thead>
              <tr class="border-b border-line text-ink-muted">
                <th class="px-4 py-2 font-medium">token</th>
                <th class="px-4 py-2 font-medium">light</th>
                <th class="px-4 py-2 font-medium">dark</th>
              </tr>
            </thead>
            <tbody class="text-ink">
              <tr
                :for={{token, light, dark} <- @surface_tokens}
                class="border-b border-line last:border-0"
              >
                <td class="px-4 py-1.5">{token}</td>
                <td class="px-4 py-1.5">{light}</td>
                <td class="px-4 py-1.5">{dark}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="space-y-3" aria-labelledby="foundations-info">
        <h2 id="foundations-info" class="text-lg font-semibold text-ink">Info accent</h2>
        <p class="text-sm text-ink-muted">
          Grove's olive carries information — callouts, hints, meta (WCAG: 6.87/7.17 on
          canvas/panel light, 11.63/10.61 dark). The rule runs both ways: the accent never marks
          actions, and links never read as info — actionable text stays amber-family
          (<span class="font-mono text-xs">--link #953c00 / #ffb66d</span>), information stays olive.
        </p>
        <div class="rounded-xl border border-line-info bg-info-muted p-4" data-testid="info-accent">
          <p class="flex items-center gap-2 text-sm font-medium text-info">
            <.icon name="hero-information-circle" class="size-5 shrink-0" />
            Informational note on the olive tint
          </p>
          <p class="mt-1 text-sm text-ink">
            Body ink on the tint keeps full contrast (14.14:1 light, 10.95:1 dark).
          </p>
        </div>
        <div class="overflow-hidden rounded-xl border border-line bg-panel">
          <table class="w-full text-left font-mono text-xs">
            <thead>
              <tr class="border-b border-line text-ink-muted">
                <th class="px-4 py-2 font-medium">token</th>
                <th class="px-4 py-2 font-medium">light</th>
                <th class="px-4 py-2 font-medium">dark</th>
              </tr>
            </thead>
            <tbody class="text-ink">
              <tr
                :for={{token, light, dark} <- @info_tokens}
                class="border-b border-line last:border-0"
              >
                <td class="px-4 py-1.5">{token}</td>
                <td class="px-4 py-1.5">{light}</td>
                <td class="px-4 py-1.5">{dark}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="space-y-3" aria-labelledby="foundations-info-vs-success">
        <h2 id="foundations-info-vs-success" class="text-lg font-semibold text-ink">
          Info vs success
        </h2>
        <p class="text-sm text-ink-muted">
          The lane accepted Grove knowing olive sits near success-green, so the separation is
          engineered, not hoped for: success was re-tuned to hold ≥40° OKLCH hue from every olive
          token with clearly separated lightness — measured 57° light / 62° dark (ΔL ≥ 0.07), still
          AA on every text pair. Warning keeps its distance too: 59° light, and dark was re-tuned
          (hue 84° → 78°, chroma nudged to stay in sRGB gamut) from 38° to 44°. The rules on top of
          the colour: status is never colour-alone (icon and label always pair), and the info
          accent never carries positive/success semantics.
        </p>
        <div class="grid gap-3 sm:grid-cols-2" data-testid="info-vs-success">
          <div class="rounded-xl border border-line-info bg-info-muted p-4">
            <p class="flex items-center gap-2 text-sm font-medium text-info">
              <.icon name="hero-information-circle" class="size-5 shrink-0" /> Info — olive
            </p>
            <p class="mt-1 text-xs text-ink-muted">
              Information only. Never reads as “done” or “OK”.
            </p>
          </div>
          <div class="rounded-xl border border-line-success bg-success-muted p-4">
            <p class="flex items-center gap-2 text-sm font-medium text-success">
              <.icon name="hero-check-circle" class="size-5 shrink-0" /> Success — teal-leaning green
            </p>
            <p class="mt-1 text-xs text-ink-muted">
              Positive states only. Never reads as “for your information”.
            </p>
          </div>
        </div>
        <div class="overflow-hidden rounded-xl border border-line bg-panel">
          <table class="w-full text-left font-mono text-xs">
            <thead>
              <tr class="border-b border-line text-ink-muted">
                <th class="px-4 py-2 font-medium">token</th>
                <th class="px-4 py-2 font-medium">light</th>
                <th class="px-4 py-2 font-medium">dark</th>
              </tr>
            </thead>
            <tbody class="text-ink">
              <tr
                :for={{token, light, dark} <- @success_tokens}
                class="border-b border-line last:border-0"
              >
                <td class="px-4 py-1.5">{token}</td>
                <td class="px-4 py-1.5">{light}</td>
                <td class="px-4 py-1.5">{dark}</td>
              </tr>
            </tbody>
          </table>
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

      <section class="space-y-3" aria-labelledby="foundations-elevation">
        <h2 id="foundations-elevation" class="text-lg font-semibold text-ink">Elevation</h2>
        <p class="text-sm text-ink-muted">
          Warm-tinted shadow scale on <span class="font-mono text-xs">rgb(38 43 43)</span>, exposed
          through the standard <span class="font-mono text-xs">shadow-xs…lg</span> utilities. In
          dark mode shadow is imperceptible on near-black surfaces, so the scale collapses to
          transparent and depth is carried by border emphasis
          (<span class="font-mono text-xs">--line-strong</span>) instead — flip the mode to see it.
        </p>
        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4" data-testid="elevation">
          <div
            :for={{name, value, class} <- @elevation}
            class={["rounded-panel border border-line bg-panel p-4 dark:border-line-strong", class]}
          >
            <p class="text-sm font-medium text-ink">{name}</p>
            <p class="mt-1 font-mono text-[10px] leading-relaxed text-ink-muted">{value}</p>
          </div>
        </div>
      </section>

      <section class="space-y-3" aria-labelledby="foundations-radius">
        <h2 id="foundations-radius" class="text-lg font-semibold text-ink">Radius</h2>
        <p class="text-sm text-ink-muted">
          Semantic radii: panels and cards go soft, controls stay crisp, pills stay full.
        </p>
        <div class="grid gap-4 sm:grid-cols-3" data-testid="radius">
          <div
            :for={{class, token, use} <- @radius}
            class={[class, "border border-line bg-panel px-4 py-3"]}
          >
            <p class="text-sm font-medium text-ink">{class}</p>
            <p class="mt-1 font-mono text-[10px] text-ink-muted">{token}</p>
            <p class="mt-0.5 text-xs text-ink-muted">{use}</p>
          </div>
        </div>
      </section>

      <section class="space-y-3" aria-labelledby="foundations-motion">
        <h2 id="foundations-motion" class="text-lg font-semibold text-ink">Motion</h2>
        <p class="text-sm text-ink-muted">
          Durations and the shared ease-out curve, defined in #277. No component consumes them yet —
          this page is the contract. The tile below consumes them inline so you can feel the curve.
        </p>
        <div class="overflow-hidden rounded-xl border border-line bg-panel">
          <table class="w-full text-left font-mono text-xs">
            <tbody class="text-ink">
              <tr :for={{token, value} <- @motion} class="border-b border-line last:border-0">
                <td class="px-4 py-1.5">{token}</td>
                <td class="px-4 py-1.5">{value}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <div
          class="w-fit cursor-default rounded-control border border-line bg-panel px-4 py-2 text-sm font-medium text-ink transition-colors hover:bg-primary-muted hover:text-link"
          style="transition-duration: var(--motion-base); transition-timing-function: var(--motion-ease-out);"
          data-testid="motion-demo"
        >
          Hover — 200ms ease-out
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
