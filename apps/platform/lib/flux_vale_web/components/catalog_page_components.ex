defmodule FluxValeWeb.CatalogPageComponents do
  @moduledoc """
  The catalog app page's sections (#611 plan §6.1, S2-S4): the hero
  with its transactional aside (pricing card, facts card), the two
  curated sections (in action, features), and the four generated
  sections (benefits, FAQ, similar apps, closing CTA), composed by the
  public SSR page (`CatalogHTML.show`). Authored content comes from
  the S1 marketing metadata (caveats, alternatives, category audience,
  screenshots, feature cards); every figure renders from code —
  Pricing, Accounts, the version defaults, WakeStats — never a literal
  (plan §5). Copy lives in `FluxValeWeb.CatalogPageContent`; the
  authenticated page re-renders the same components in S6.
  """

  use FluxValeWeb, :html

  alias FluxVale.Accounts
  alias FluxVale.Pricing
  alias FluxValeWeb.CatalogPageContent

  @doc """
  The page hero (plan §6.4): prose column plus the sticky aside. The
  description keeps the catalog's `whitespace-pre-line` rendering so
  authored paragraph breaks survive. The aside stacks after the prose
  on mobile.
  """
  attr(:app, :any, required: true, doc: "the Catalog.App, :category loaded")

  attr(:newest_version, :any,
    default: nil,
    doc: "newest AppVersion (:recommended_size loaded), nil when the app has none"
  )

  attr(:wake_estimates, :map,
    required: true,
    doc: "WakeStats.median_total_by_app_safe/0 — the facts card's Wakes in row"
  )

  # #611 S6: the same hero serves both surfaces, so the back link's
  # target is the caller's: /catalog on the public page, /apps on the
  # authenticated one (both are labelled Catalog in the chrome).
  attr(:back_path, :string,
    default: "/catalog",
    doc: "back link target: /catalog public, /apps authenticated"
  )

  @spec hero(map()) :: Phoenix.LiveView.Rendered.t()
  def hero(assigns) do
    ~H"""
    <div class="grid gap-10 lg:grid-cols-[minmax(0,1fr)_22rem]">
      <div class="min-w-0 max-w-prose">
        <.button variant="ghost" size="sm" navigate={@back_path} class="-ml-2">
          &larr; {gettext("Catalog")}
        </.button>

        <p class="eyebrow mt-6">{@app.category.name}</p>

        <%!-- Plan §3's icon-led hero row (#611 review ruling): the
        authenticated page's tile idiom beside the display title. The
        img is decorative — the h1 names the app. --%>
        <div class="mt-6 flex items-center gap-3 sm:gap-4">
          <div
            class="grid size-12 shrink-0 place-items-center rounded-control bg-primary-muted text-lg font-semibold text-link sm:size-14 sm:text-xl"
            data-testid="app-icon"
          >
            <img
              :if={@app.icon_url}
              src={@app.icon_url}
              alt=""
              class="size-8 rounded-control sm:size-9"
            />
            <span :if={is_nil(@app.icon_url)}>{String.first(@app.name)}</span>
          </div>
          <h1 class="display">{gettext("%{name} hosting", name: @app.name)}</h1>
        </div>

        <p class="mt-4 text-lg leading-relaxed text-ink-muted">
          {gettext("Managed %{name}, ready in minutes.", name: @app.name)}
        </p>

        <div class="mt-6 space-y-4">
          <p
            :if={is_binary(@app.description) and String.trim(@app.description) != ""}
            class="leading-relaxed text-ink-muted"
          >
            <%!-- pre-line rides the span: the p's own whitespace is
            normal, so the template's indentation newlines collapse
            instead of laying out a phantom blank line (the catalog
            poster's T4 fix, kept verbatim). --%>
            <span class="whitespace-pre-line">{String.trim(@app.description)}</span>
          </p>

          <%!-- The category's S1 audience line — the "who it suits"
          paragraph, one authored sentence per category. --%>
          <p :if={@app.category.audience} class="leading-relaxed text-ink-muted">
            {@app.category.audience}
          </p>

          <%!-- Facts, not errors: a bordered panel with the mono
          eyebrow, never a warning callout (plan §6.4). `not in` guards
          nil too: the fields are nullable (the OpenAPI stance) and a
          YAML `caveats:` null seeds nil — `nil != []` alone would let
          the for crash the public page. --%>
          <div :if={@app.caveats not in [nil, []]} class="rounded-panel border border-line p-5">
            <p class="eyebrow">{gettext("Worth knowing")}</p>
            <ul class="mt-3 list-disc space-y-2 pl-5 text-sm text-ink-muted">
              <li :for={caveat <- @app.caveats} class="[overflow-wrap:anywhere]">{caveat}</li>
            </ul>
          </div>

          <p :if={@app.alternatives not in [nil, []]} class="leading-relaxed text-ink-muted">
            {alternative_to(@app.alternatives)}
          </p>

          <%!-- The reader's exits. The FAQ link jumps the page's own
          FAQ section (S3) — same tab, unlike the external rows. --%>
          <div class="flex flex-wrap items-center gap-x-6 gap-y-2 pt-2 text-sm">
            <.hero_link
              :if={@app.source_url}
              href={@app.source_url}
              icon="hero-arrow-top-right-on-square"
            >
              {gettext("Source")}
            </.hero_link>
            <.hero_link :if={@app.docs_url} href={@app.docs_url} icon="hero-book-open">
              {gettext("Docs")}
            </.hero_link>
            <.hero_link
              :if={@app.community_url}
              href={@app.community_url}
              icon="hero-chat-bubble-left-right"
            >
              {gettext("Community")}
            </.hero_link>
            <.hero_link href="#faq" icon="hero-question-mark-circle" internal?>
              {gettext("FAQ")}
            </.hero_link>
          </div>
        </div>
      </div>

      <aside class="space-y-4 lg:sticky lg:top-20 lg:self-start">
        <.pricing_card :if={@newest_version} app={@app} newest_version={@newest_version} />
        <.facts_card
          app={@app}
          newest_version={@newest_version}
          wake_estimates={@wake_estimates}
        />
      </aside>
    </div>
    """
  end

  @doc """
  The transaction card (plan §6.4, §7.2): the recommended rate, the
  recommended size, the platform checklist, the deploy CTA, the
  billing fine print. The whole card rides on a newest version — the
  CTA matches the authenticated page's no-versions rule.
  """
  attr(:app, :any, required: true, doc: "the Catalog.App")

  attr(:newest_version, :any,
    required: true,
    doc: "the newest AppVersion, :recommended_size loaded"
  )

  @spec pricing_card(map()) :: Phoenix.LiveView.Rendered.t()
  def pricing_card(assigns) do
    assigns =
      assigns
      |> assign(:rates, Pricing.version_rates(assigns.newest_version))
      |> assign(:welcome_credit, Pricing.format_usd(Accounts.welcome_grant_cents()))
      |> assign(:oidc?, oidc?(assigns.newest_version))

    ~H"""
    <.card id="pricing-card" class="space-y-5 p-6">
      <%!-- A sizeless version hides the whole rate group — "Starts at"
      without a figure is meaningless — and never crashes (the
      price_badge rule). --%>
      <div :if={@rates}>
        <p class="text-sm font-medium text-ink-muted">{gettext("Starts at")}</p>
        <p class="mt-1 font-mono text-3xl font-semibold tracking-tight text-ink">
          {gettext("%{rate}/mo", rate: Pricing.format_usd(@rates.monthly_cents))}
        </p>
        <p class="mt-1 text-sm text-ink-muted">{gettext("billed hourly from your wallet")}</p>
      </div>

      <div>
        <p class="text-sm font-medium text-ink-muted">{gettext("Recommended size")}</p>
        <%!-- nowrap spans so a narrow card wraps BETWEEN specs (leading
        middots), never strands "storage" alone mid-phrase. --%>
        <p class="mt-1.5 flex flex-wrap gap-x-1.5 gap-y-0.5 font-mono text-sm text-ink">
          <span class="whitespace-nowrap">
            {gettext("%{cpu} CPU", cpu: @newest_version.default_cpu_cores)}
          </span>
          <span class="whitespace-nowrap">
            · {gettext("%{memory} MB RAM", memory: @newest_version.default_memory_mb)}
          </span>
          <span class="whitespace-nowrap">
            · {gettext("%{storage} GB storage", storage: @newest_version.default_storage_gb)}
          </span>
        </p>
      </div>

      <ul class="space-y-2.5 text-sm text-ink">
        <li class="flex gap-2.5">
          <.icon name="hero-check" class="mt-0.5 size-4 shrink-0 text-success" />
          {gettext("Start with %{amount} in welcome credit", amount: @welcome_credit)}
        </li>
        <li class="flex gap-2.5">
          <.icon name="hero-check" class="mt-0.5 size-4 shrink-0 text-success" />
          {gettext("Free HTTPS on a fluxvale.app address")}
        </li>
        <li class="flex gap-2.5">
          <.icon name="hero-check" class="mt-0.5 size-4 shrink-0 text-success" />
          {gettext("Sleeps when idle, wakes on the next visit")}
        </li>
        <li class="flex gap-2.5">
          <.icon name="hero-check" class="mt-0.5 size-4 shrink-0 text-success" />
          {gettext("Nightly backups to your own S3 bucket")}
        </li>
        <li :if={@oidc?} class="flex gap-2.5" data-testid="check-sso">
          <.icon name="hero-check" class="mt-0.5 size-4 shrink-0 text-success" />
          {gettext("Sign in with your Pocket ID")}
        </li>
        <li :if={@app.file_access} class="flex gap-2.5" data-testid="check-webdav">
          <.icon name="hero-check" class="mt-0.5 size-4 shrink-0 text-success" />
          {gettext("Move files in over WebDAV")}
        </li>
      </ul>

      <.button
        navigate={~p"/apps/#{@app.slug}/deploy"}
        id="deploy-cta"
        data-testid="deploy-cta"
        class="w-full"
      >
        {gettext("Deploy %{name}", name: @app.name)}
      </.button>

      <p class="text-xs text-ink-subtle">
        {gettext(
          "Monthly equivalent, billed hourly. Storage bills while stopped. VAT is added to top-ups for EU customers."
        )}
      </p>
    </.card>
    """
  end

  @doc """
  The facts card (plan §6.4, D7): what a buyer needs instead of
  GitHub stars. Always renders; rows drop out individually when their
  source is absent.
  """
  attr(:app, :any, required: true, doc: "the Catalog.App")

  attr(:newest_version, :any,
    default: nil,
    doc: "newest AppVersion, nil when the app has none — drops the Version, Updated and SSO rows"
  )

  attr(:wake_estimates, :map, required: true, doc: "WakeStats.median_total_by_app_safe/0")

  @spec facts_card(map()) :: Phoenix.LiveView.Rendered.t()
  def facts_card(assigns) do
    assigns =
      assigns
      |> assign(:wake_estimate, Map.get(assigns.wake_estimates, assigns.app.slug))
      |> assign(:oidc?, oidc?(assigns.newest_version))

    ~H"""
    <.card id="facts-card" class="p-6">
      <dl class="space-y-3 text-sm">
        <div :if={@newest_version} class="flex items-center gap-2.5" data-testid="fact-version">
          <.icon name="hero-tag" class="size-4 shrink-0 text-ink-subtle" />
          <dt class="text-ink-muted">{gettext("Version")}</dt>
          <dd class="ml-auto font-mono text-ink">v{@newest_version.version}</dd>
        </div>

        <%!-- Relative age with the full ISO date in the title for
        precision (plan §6.4). --%>
        <div
          :if={@newest_version && @newest_version.published_at}
          class="flex items-center gap-2.5"
          data-testid="fact-updated"
        >
          <.icon name="hero-clock" class="size-4 shrink-0 text-ink-subtle" />
          <dt class="text-ink-muted">{gettext("Updated")}</dt>
          <dd
            class="ml-auto font-mono text-ink"
            title={DateTime.to_iso8601(@newest_version.published_at)}
          >
            {relative_updated(@newest_version.published_at)}
          </dd>
        </div>

        <div :if={@wake_estimate} class="flex items-center gap-2.5" data-testid="fact-wakes">
          <.icon name="hero-bolt" class="size-4 shrink-0 text-ink-subtle" />
          <dt class="text-ink-muted">{gettext("Wakes in")}</dt>
          <dd class="ml-auto font-mono text-ink">{format_estimate(@wake_estimate)}</dd>
        </div>

        <%!-- One region, honestly (#178's stance; ADR-0020's cluster is
        Nuremberg) — the copy says so rather than implying choice. --%>
        <div class="flex items-center gap-2.5" data-testid="fact-region">
          <.icon name="hero-globe-alt" class="size-4 shrink-0 text-ink-subtle" />
          <dt class="text-ink-muted">{gettext("Region")}</dt>
          <dd class="ml-auto font-mono text-ink">{gettext("Nuremberg, EU")}</dd>
        </div>

        <div class="flex items-center gap-2.5" data-testid="fact-backups">
          <.icon name="hero-archive-box" class="size-4 shrink-0 text-ink-subtle" />
          <dt class="text-ink-muted">{gettext("Backups")}</dt>
          <dd class="ml-auto font-mono text-ink">{gettext("Your S3 bucket")}</dd>
        </div>

        <div :if={@oidc?} class="flex items-center gap-2.5" data-testid="fact-sso">
          <.icon name="hero-finger-print" class="size-4 shrink-0 text-ink-subtle" />
          <dt class="text-ink-muted">{gettext("SSO")}</dt>
          <dd class="ml-auto font-mono text-ink">{gettext("Pocket ID")}</dd>
        </div>

        <div :if={@app.file_access} class="flex items-center gap-2.5" data-testid="fact-file-access">
          <.icon name="hero-folder-open" class="size-4 shrink-0 text-ink-subtle" />
          <dt class="text-ink-muted">{gettext("File access")}</dt>
          <dd class="ml-auto font-mono text-ink">{gettext("WebDAV")}</dd>
        </div>
      </dl>
    </.card>
    """
  end

  @doc """
  The curated "in action" section (plan §6.4, S4): real-UI screenshots
  in bordered frames — proof, not claims. Omission is the designed
  absent state (plan §5): nil and [] render nothing and leave no gap,
  and the intro line rides the authored `in_action_intro` with no
  generated fallback. One screenshot renders as a single wide frame;
  two or more as a 2-column grid at sm, three or four wrapping 2x2.
  Data comes from the S1 type — src, alt, caption verbatim, never an
  invented caption.
  """
  attr(:app, :any, required: true, doc: "the Catalog.App")

  @spec in_action(map()) :: Phoenix.LiveView.Rendered.t()
  def in_action(assigns) do
    ~H"""
    <section
      :if={@app.screenshots not in [nil, []]}
      class="border-t border-line py-14 sm:py-16"
      data-testid="in-action-section"
    >
      <p class="eyebrow">{gettext("In action")}</p>
      <h2 class="display-h2">{gettext("%{name} in action", name: @app.name)}</h2>
      <%!-- Authored or absent — no generated fallback (plan §3). `not
      in` guards nil like the hero's caveats: the field is nullable and
      a hostile null must not crash the public page. --%>
      <p :if={@app.in_action_intro} class="mt-4 text-lg leading-relaxed text-ink-muted">
        {@app.in_action_intro}
      </p>

      <div class={["mt-10 grid gap-4", if(length(@app.screenshots) > 1, do: "sm:grid-cols-2")]}>
        <figure
          :for={shot <- @app.screenshots}
          class="overflow-hidden rounded-panel border border-line-strong bg-panel"
          data-testid="screenshot-frame"
        >
          <%!-- Fixed 16:10 aspect plus explicit dimensions: no CLS as
          the lazy image loads (plan §6.5). alt is validation-backed
          (10-140 chars, S1), so the frame never ships empty alt text. --%>
          <img
            src={shot.src}
            alt={shot.alt}
            loading="lazy"
            decoding="async"
            width="1440"
            height="900"
            class="aspect-[16/10] w-full object-cover"
          />
          <figcaption :if={shot.caption} class="px-5 py-4 text-sm text-ink-muted">
            {shot.caption}
          </figcaption>
        </figure>
      </div>
    </section>
    """
  end

  @doc """
  The curated feature grid (plan §6.4, S4): 2x2 at sm, one column
  below — the app's own capabilities as authored cards. The icon rides
  the S1 allowlist, validated at write time by `Types.FeatureList`, so
  a bad icon fails the seed, not the page. Cards are not links: no
  hover lift, just the catalog card's icon-in-tile idiom. Omission is
  the designed absent state (plan §5).
  """
  attr(:app, :any, required: true, doc: "the Catalog.App")

  @spec features(map()) :: Phoenix.LiveView.Rendered.t()
  def features(assigns) do
    ~H"""
    <section
      :if={@app.features not in [nil, []]}
      class="border-t border-line py-14 sm:py-16"
      data-testid="features-section"
    >
      <p class="eyebrow">{gettext("Features")}</p>
      <h2 class="display-h2">{gettext("What you can do with %{name}", name: @app.name)}</h2>

      <div class="mt-10 grid gap-4 sm:grid-cols-2">
        <div
          :for={feature <- @app.features}
          class="rounded-panel border border-line-strong bg-panel p-6"
          data-testid="feature-card"
        >
          <div class="flex items-center gap-3">
            <%!-- The catalog card's icon-in-tile idiom (#277 T4),
            verbatim — one silhouette across the surface. --%>
            <div class="grid size-9 shrink-0 place-items-center rounded-control bg-primary-muted text-sm font-semibold text-link">
              <.icon name={feature.icon} class="size-5" />
            </div>
            <h3 class="min-w-0 text-base font-semibold text-ink [overflow-wrap:anywhere]">
              {feature.title}
            </h3>
          </div>
          <p class="mt-3 text-sm leading-relaxed text-ink-muted">{feature.body}</p>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  The benefits section (plan §6.4, §7.4, D8): the 2-column platform
  checklist with the conditional SSO and WebDAV rows, and the trailing
  "How FluxVale works" link. Always renders — every row is a platform
  constant or rides declared metadata.
  """
  attr(:app, :any, required: true, doc: "the Catalog.App")

  attr(:newest_version, :any,
    default: nil,
    doc: "newest AppVersion — gates the SSO row on its OIDC declaration"
  )

  @spec benefits(map()) :: Phoenix.LiveView.Rendered.t()
  def benefits(assigns) do
    assigns =
      assign(
        assigns,
        :rows,
        CatalogPageContent.benefits(%{
          oidc?: oidc?(assigns.newest_version),
          file_access?: assigns.app.file_access
        })
      )

    ~H"""
    <section class="border-t border-line py-14 sm:py-16" data-testid="benefits-section">
      <p class="eyebrow">{gettext("Why FluxVale")}</p>
      <h2 class="display-h2">
        {gettext("Benefits of hosting %{name} on FluxVale", name: @app.name)}
      </h2>

      <ul class="mt-10 grid gap-x-10 gap-y-6 sm:grid-cols-2">
        <li :for={row <- @rows} class="flex gap-3" data-testid="benefit-row">
          <.icon name="hero-check" class="mt-0.5 size-5 shrink-0 text-success" />
          <div>
            <p class="text-sm font-semibold text-ink">{row.title}</p>
            <p class="mt-1 text-sm leading-relaxed text-ink-muted">{row.body}</p>
          </div>
        </li>
      </ul>

      <.link
        navigate={~p"/docs/getting-started/first-app"}
        class="mt-10 inline-flex items-center gap-1.5 text-sm font-medium text-link hover:underline"
      >
        {gettext("How FluxVale works")}
        <.icon name="hero-arrow-right" class="size-4" />
      </.link>
    </section>
    """
  end

  @doc """
  The FAQ section (plan §6.4, §7.5, D11): two columns at lg, one
  bordered panel per column, native details/summary rows — zero
  JavaScript, keyboard native, crawlable closed. The data-ownership
  answer carries `open`. Items come from CatalogPageContent; the
  app's own FAQ rides the about column only.
  """
  attr(:app, :any, required: true, doc: "the Catalog.App")

  attr(:newest_version, :any,
    default: nil,
    doc: "newest AppVersion — gates the Pocket ID row on its OIDC declaration"
  )

  @spec faq(map()) :: Phoenix.LiveView.Rendered.t()
  def faq(assigns) do
    assigns =
      assigns
      |> assign(
        :setup_items,
        CatalogPageContent.faq_setup_items(assigns.app, assigns.newest_version)
      )
      |> assign(:about_items, CatalogPageContent.faq_about_items(assigns.app))

    ~H"""
    <section
      class="border-t border-line py-14 scroll-mt-16 sm:py-16"
      id="faq"
      data-testid="faq-section"
    >
      <p class="eyebrow">{gettext("FAQ")}</p>
      <h2 class="display-h2">{gettext("Frequently asked questions")}</h2>

      <div class="mt-10 grid gap-10 lg:grid-cols-2">
        <div data-testid="faq-setup-column">
          <p class="eyebrow">{gettext("Setting up %{name}", name: @app.name)}</p>
          <div class="mt-4 divide-y divide-line rounded-panel border border-line">
            <.faq_row :for={item <- @setup_items} item={item} />
          </div>
        </div>

        <div data-testid="faq-about-column">
          <p class="eyebrow">{gettext("About %{name} and FluxVale", name: @app.name)}</p>
          <div class="mt-4 divide-y divide-line rounded-panel border border-line">
            <.faq_row :for={item <- @about_items} item={item} />
          </div>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  The similar-apps section (plan §6.4, D6): same-category peers, 2-up
  at sm, mirroring the catalog index card. Fewer than two peers shows
  one browse card — no invented similarity. The from-price is the
  compute floor, computed once per request by the controller.
  """
  attr(:peers, :list, required: true, doc: "CatalogPageContent.similar_apps/2 — self excluded")

  attr(:from_price_cents, :any,
    default: nil,
    doc: "Pricing.from_price_cents/0 — nil hides the footer line (the index rule)"
  )

  @spec similar_apps(map()) :: Phoenix.LiveView.Rendered.t()
  def similar_apps(assigns) do
    ~H"""
    <section class="border-t border-line py-14 sm:py-16" data-testid="similar-section">
      <p class="eyebrow">{gettext("Similar apps")}</p>
      <h2 class="display-h2">{gettext("Similar apps on FluxVale")}</h2>

      <div class="mt-10 grid gap-4 sm:grid-cols-2">
        <.peer_card
          :for={peer <- @peers}
          :if={length(@peers) >= 2}
          app={peer}
          from_price_cents={@from_price_cents}
        />
        <.browse_card :if={length(@peers) < 2} />
      </div>
    </section>
    """
  end

  @doc """
  The closing CTA (plan §6.4, §7.6): centered, the welcome-credit
  line, one primary deploy button and one ghost catalog link. The
  primary hides when the app has no versions, matching the pricing
  card's rule.
  """
  attr(:app, :any, required: true, doc: "the Catalog.App")

  attr(:newest_version, :any,
    default: nil,
    doc: "newest AppVersion — nil (no versions) hides the deploy button"
  )

  @spec closing_cta(map()) :: Phoenix.LiveView.Rendered.t()
  def closing_cta(assigns) do
    assigns = assign(assigns, :copy, CatalogPageContent.closing_cta(assigns.app.name))

    ~H"""
    <section class="border-t border-line py-14 text-center sm:py-16" data-testid="cta-section">
      <h2 class="display-h2">{@copy.heading}</h2>
      <p class="mt-4 text-lg leading-relaxed text-ink-muted">{@copy.sub}</p>

      <div class="mt-8 flex flex-wrap items-center justify-center gap-3">
        <.button
          :if={@newest_version}
          navigate={~p"/apps/#{@app.slug}/deploy"}
          data-testid="cta-deploy"
        >
          {@copy.primary}
        </.button>
        <.button variant="ghost" navigate={~p"/catalog"} data-testid="cta-browse">
          {@copy.ghost}
        </.button>
      </div>
    </section>
    """
  end

  # One FAQ row: native details/summary, the chevron rotating on
  # [open] via group-open. The answer stays in the DOM closed —
  # crawlable (plan §6.4), and `open` renders only when true.
  attr(:item, :any, required: true, doc: "a CatalogPageContent.faq_item")

  defp faq_row(assigns) do
    ~H"""
    <details class="group" open={@item.open}>
      <summary class="flex cursor-pointer list-none items-center justify-between gap-4 px-5 py-4 text-sm font-medium text-ink outline-offset-2 outline-focus focus-visible:outline-2 transition-colors duration-(--motion-fast) hover:text-link [&::-webkit-details-marker]:hidden">
        <span class="min-w-0 [overflow-wrap:anywhere]">{@item.question}</span>
        <.icon
          name="hero-chevron-down"
          class="size-4 shrink-0 text-ink-subtle transition-transform duration-(--motion-base) ease-(--motion-ease-out) group-open:rotate-180"
        />
      </summary>
      <div class="px-5 pb-5 text-sm leading-relaxed text-ink-muted">
        <p class="[overflow-wrap:anywhere]">{@item.answer}</p>
        <.link
          :if={@item.link}
          navigate={@item.link.href}
          class="mt-2 inline-flex items-center gap-1 font-medium text-link hover:underline"
        >
          {@item.link.label}
          <.icon name="hero-arrow-right" class="size-3.5" />
        </.link>
      </div>
    </details>
    """
  end

  # A similar-app card — the catalog index card's shape: icon tile,
  # name, two-line tagline clamp, from-price footer. A linked card, so
  # it carries the hover lift (plan §6.5).
  attr(:app, :any, required: true, doc: "the peer Catalog.App")

  attr(:from_price_cents, :any, default: nil, doc: "nil hides the footer line")

  defp peer_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/catalog/#{@app.slug}"}
      data-testid={"similar-#{@app.slug}"}
      class="group block rounded-panel border border-line-strong bg-panel p-5 shadow-sm outline-offset-2 outline-focus focus-visible:outline-2 transition-[box-shadow] duration-(--motion-base) ease-(--motion-ease-out) hover:shadow-md"
    >
      <div class="transition-[translate] duration-(--motion-base) ease-(--motion-ease-out) motion-safe:group-hover:-translate-y-1">
        <div class="flex items-center gap-3">
          <div class="grid size-9 shrink-0 place-items-center rounded-control bg-primary-muted text-sm font-semibold text-link">
            <img
              :if={@app.icon_url}
              src={@app.icon_url}
              alt={@app.name}
              class="size-6 rounded-control"
            />
            <span :if={is_nil(@app.icon_url)}>{String.first(@app.name)}</span>
          </div>
          <h3 class="min-w-0 flex-1 text-base font-medium text-ink transition-colors duration-(--motion-fast) [overflow-wrap:anywhere] group-hover:text-link">
            {@app.name}
          </h3>
        </div>
        <p :if={@app.tagline} class="mt-2.5 line-clamp-2 min-h-10 text-sm text-ink-muted">
          {@app.tagline}
        </p>
        <p
          :if={not is_nil(@from_price_cents)}
          class="mt-2 text-xs font-medium text-ink"
          data-testid="similar-from-price"
        >
          {gettext("From %{rate}/mo plus storage", rate: Pricing.format_usd(@from_price_cents))}
        </p>
      </div>
    </.link>
    """
  end

  # The under-two-peers fallback (D6): one card out to the catalog
  # index. No invented similarity, no per-app claims.
  defp browse_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/catalog"}
      data-testid="browse-card"
      class="group block rounded-panel border border-line-strong bg-panel p-5 shadow-sm outline-offset-2 outline-focus focus-visible:outline-2 transition-[box-shadow] duration-(--motion-base) ease-(--motion-ease-out) hover:shadow-md"
    >
      <div class="transition-[translate] duration-(--motion-base) ease-(--motion-ease-out) motion-safe:group-hover:-translate-y-1">
        <div class="flex items-center gap-3">
          <div class="grid size-9 shrink-0 place-items-center rounded-control bg-primary-muted text-sm font-semibold text-link">
            <.icon name="hero-squares-2x2" class="size-5" />
          </div>
          <h3 class="min-w-0 flex-1 text-base font-medium text-ink transition-colors duration-(--motion-fast) [overflow-wrap:anywhere] group-hover:text-link">
            {gettext("Browse the catalog")}
          </h3>
        </div>
        <p class="mt-2.5 line-clamp-2 min-h-10 text-sm text-ink-muted">
          {gettext("The whole catalog on one page.")}
        </p>
      </div>
    </.link>
    """
  end

  @doc """
  The hero's positioning line (plan §7.1): one name "An alternative
  to X.", two "An alternative to X and Y.", three or more "An
  alternative to X, Y and Z." — no Oxford comma. nil (a nullable
  field) or [] is the designed absent state (plan §5).
  """
  @spec alternative_to([String.t()] | nil) :: String.t() | nil
  def alternative_to(nil), do: nil

  def alternative_to([]), do: nil

  def alternative_to([name]),
    do: gettext("An alternative to %{name}.", name: name)

  def alternative_to([one, two]),
    do: gettext("An alternative to %{one} and %{two}.", one: one, two: two)

  def alternative_to([_first | _rest] = names) do
    {lead_names, [last]} = Enum.split(names, -1)
    lead = Enum.join(lead_names, ", ")

    gettext("An alternative to %{lead} and %{last}.", lead: lead, last: last)
  end

  @doc """
  The facts card's Updated value: "today", "yesterday", or "%{count}d
  ago" by whole days. nil when published_at is nil (the row drops). A
  future timestamp clamps to today — seed drift reads as fresh, never
  as a negative age.
  """
  @spec relative_updated(DateTime.t() | nil) :: String.t() | nil
  def relative_updated(nil), do: nil

  def relative_updated(%DateTime{} = published_at) do
    published_date = DateTime.to_date(published_at)
    days = max(Date.diff(Date.utc_today(), published_date), 0)

    case days do
      0 -> gettext("today")
      1 -> gettext("yesterday")
      n -> gettext("%{count}d ago", count: n)
    end
  end

  # The link row's icon-plus-text exits (plan §6.4). External links
  # open a new tab; internal targets (the FAQ anchor) must not — the
  # same page in a second tab is a dead end.
  attr(:href, :string, required: true)
  attr(:icon, :string, required: true)

  attr(:internal?, :boolean,
    default: false,
    doc: "same-tab navigation (anchors, internal routes)"
  )

  slot(:inner_block, required: true)

  defp hero_link(assigns) do
    ~H"""
    <a
      href={@href}
      target={if(@internal?, do: nil, else: "_blank")}
      rel={if(@internal?, do: nil, else: "noopener")}
      class="inline-flex items-center gap-1.5 font-medium text-link hover:underline"
    >
      <.icon name={@icon} class="size-4" />
      {render_slot(@inner_block)}
    </a>
    """
  end

  # The version declares an OIDC consumer surface either way (the
  # oidc_callback_path stance): a callback path to register, or the
  # #597 automatic wiring recipe.
  defp oidc?(nil), do: false

  defp oidc?(version),
    do: not is_nil(version.oidc_callback_path) or not is_nil(version.oidc_wiring)

  # The "~4s" copy, the catalog index badge's exact register — one
  # honest estimate, rounded to the second, minutes-and-seconds over
  # a minute. A deliberate view-layer twin of Index's private copy
  # (the price_badge precedent: one shape, two lanes).
  defp format_estimate(seconds) do
    rounded = round(seconds)

    if rounded < 60 do
      "~#{rounded}s"
    else
      "~#{div(rounded, 60)}m #{rem(rounded, 60)}s"
    end
  end
end
