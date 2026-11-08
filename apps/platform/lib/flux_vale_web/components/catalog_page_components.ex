defmodule FluxValeWeb.CatalogPageComponents do
  @moduledoc """
  The catalog app page's sections (#611 plan §6.1, S2): the hero with
  its transactional aside (pricing card, facts card), composed by the
  public SSR page (`CatalogHTML.show`). Authored content comes from
  the S1 marketing metadata (caveats, alternatives, category
  audience); every figure renders from code — Pricing, Accounts, the
  version defaults, WakeStats — never a literal (plan §5). The
  authenticated page re-renders the same components in S6.
  """

  use FluxValeWeb, :html

  alias FluxVale.Accounts
  alias FluxVale.Pricing

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

  @spec hero(map()) :: Phoenix.LiveView.Rendered.t()
  def hero(assigns) do
    ~H"""
    <div class="grid gap-10 lg:grid-cols-[minmax(0,1fr)_22rem]">
      <div class="min-w-0 max-w-prose">
        <.button variant="ghost" size="sm" navigate={~p"/catalog"} class="-ml-2">
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

          <%!-- The reader's exits. The FAQ anchor arrives with S3 —
          no dead #faq link meanwhile. --%>
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

  # The link row's icon-plus-text exits (plan §6.4).
  attr(:href, :string, required: true)
  attr(:icon, :string, required: true)
  slot(:inner_block, required: true)

  defp hero_link(assigns) do
    ~H"""
    <a
      href={@href}
      target="_blank"
      rel="noopener"
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
