defmodule FluxValeWeb.CatalogLive.Deploy do
  @moduledoc """
  The deploy stepper (#74): pick AppVersion → env vars (schema-rendered,
  #70) → resources (#180) → name → Instance. One
  `AshPhoenix.Form.for_create/4` carries the whole flow (ADR-0002:
  forms straight onto resources); steps are UI state, not separate
  forms. The version steps carry ADR-0028's live $X.XX/mo estimate.

  The resources step (#180): CPU/memory default to the version's
  recommended compute (kept equal to the `recommended_size` compute
  class by ValidateSizeMatchesAllocation); storage defaults to the
  version's own `default_storage_gb` — the app's honest per-app
  default, priced per GB on its own axis since #558 decoupled the
  two. Above the recommendation is unrestricted; below shows a
  heads-up ("it may run slowly or fail") and requires an explicit
  acknowledgment before Continue proceeds — a wizard-level gate,
  mirroring the env step's client-controlled order (the platform's
  own guardrails are the Instance attribute constraints, enforced
  regardless of acknowledgment).

  The allocation is **selected, never typed** (#195) and **rungs-only**
  (#221, the owner's call closing #195's control-shape question): the
  seeded `Size` rows are quick-pick buttons (compute classes since
  #558 — a pick moves CPU/memory and leaves the storage rung the
  user's) and each dimension's slider steps through that ladder's
  rungs — index-based
  (`AllocationSliders.resource_dimensions/0`), so one arrow press is
  one rung and the thumb never rests between rungs. No text control
  renders on this step, and every allocation the state can hold is a
  rung by construction: `initial_resources/1` floors the version
  default to the next rung at or above it, `preset_sizes/1` filters
  the picks to representable sizes, and
  `AllocationSliders.resource_strings/2` maps slider indices back to
  rungs — a crafted index that names no rung is silence, like an
  unknown preset slug. The form cast on save stays the
  authoritative say.

  Pricing follows the allocation (#186, storage on its own axis since
  #558): at the recommended compute the estimate is the compute
  class's rate plus the per-GB storage rate at the chosen rung (a
  storage move walks the axis without leaving the size); custom
  compute prices the whole allocation by the anchor formula
  (ADR-0028's price = f(allocation), docs/pricing-calibration.md) —
  the same cents the ledger snapshots at create, so the shown price
  is the charged price by construction.

  Submit = `create` → `deploy` → the instance's status page — matching
  the M3 exit demo. Schema defaults are merged server-side
  (DeriveFromAppVersion), so only user-set values ride the form; empty
  inputs are dropped rather than overriding a default with "". Step
  transitions validate only the fields that step owns — :name's absence
  must not bounce the env step.

  The band carries the org context (#408): a compact picker names the
  org the instance deploys into (the create's `organization_id`
  argument), defaulting to the actor's personal org. Origin-tracking
  (defaulting to the org a browse started from) is declared v1
  residual: the picker is the scope, the default stays Personal.

  The Pocket ID SSO offer (#597 S3, D2/D7): on step 2, above the
  manual env form, when ALL hold — the version carries an
  `oidc_wiring` recipe (S1), the target org has an active public
  Pocket ID (the detection read), and the `pocketid_sso_wiring` flag
  is on (fail-closed: unseeded in prod until S4 completes the flow,
  so no user sees a toggle that wires nothing yet). The card has four
  states (offer / mid-setup / no-custody / unreachable); the offer's
  checkbox is UNTICKED by default (D7 — prefilling sign-in into a new
  app is a behavior change the user must choose), and ticking it
  hides the recipe's manual env inputs (the platform writes them,
  S4) while everything else stays. The probe answer and the choice
  ride wizard state only — the submit path is untouched until S4.

  Bundled backing services (#612 S3, ADR-0045): a declaring version
  owns its `url_env` keys — those inputs never render (the deploy
  composes the values; a typed value would be refused at create), and
  a note says so. Its resources step is FLOORED at the version's
  defaults (D4/D5: under-sizing starves the DBs, so the below-
  recommendation ack path is closed for them) — the sliders and the
  quick picks never offer less, the 0-GB storage rung hides with
  them, and plain copy discloses the share ("includes PostgreSQL 18
  and Redis 8"). The create's own floor validation is the
  authoritative gate; the wizard keeps every honest click inside it.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Catalog
  alias FluxVale.Catalog.Types.BackingService
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.PocketIdCustody
  alias FluxVale.Ops.FeatureFlags
  alias FluxVale.Pricing.Size
  alias FluxValeWeb.AllocationSliders

  # #597 D7: the offer's checkbox starts cold. Ticking is an explicit
  # choice — the platform must never prefill sign-in into a new app.
  @pocketid_offer_default_unticked false

  @impl Phoenix.LiveView
  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Catalog.App.get_by_slug(slug, actor: user) do
      {:ok, app} ->
        app = Ash.load!(app, [app_versions: :recommended_size], actor: user)
        versions = Enum.sort_by(app.app_versions, & &1.version, :desc)
        org_options = org_options(socket.assigns)

        socket =
          socket
          |> assign(app: app, versions: versions)
          |> assign(step: 1, version_id: nil, selected: nil, env_values: %{}, schema: %{})
          |> assign(resources: nil, below_recommendation?: false, below_ack: false)
          |> assign(:pricing_sizes, preset_sizes(user))
          |> assign(:org_options, org_options)
          |> assign(:org_id, default_org_id(org_options, socket.assigns.personal_org_id))
          # #597 S3: the Pocket ID offer's wizard-lifetime state — the
          # card state (nil = nothing renders), the probe cache (one
          # answer per Pocket ID instance, kept for the wizard's life),
          # and the tick + chosen instance riding toward S4's submit
          # wiring.
          |> assign(:pocketid_offer, nil)
          |> assign(:pocketid_probes, %{})
          |> assign(:pocketid_ticked, @pocketid_offer_default_unticked)
          |> assign(:pocketid_instance_id, nil)
          |> assign(
            :form,
            Instance
            |> AshPhoenix.Form.for_create(:create, actor: user, as: "instance")
            |> to_form()
          )

        {:ok, socket}

      _error ->
        {:ok,
         socket
         |> put_flash(:error, "App not found.")
         |> push_navigate(to: ~p"/apps")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    # Resolve once per render: the quick-pick rows (pressed/recommended
    # state — `aria-pressed` is a string attribute, a bare boolean
    # renders as an empty value and announces nothing), and the env
    # form's visible schema — the recipe's inputs render only while the
    # offer is unticked (or absent): a ticked offer means the platform
    # writes those values (#597 S3→S4), so the manual inputs vanish and
    # everything else stays.
    assigns =
      assign(assigns,
        presets: preset_options(assigns),
        floors: resource_floors(assigns.selected),
        visible_schema: visible_schema(assigns)
      )

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
      <%!-- App-wide grammar page (S8): `bare` main + .appgram — the page
      owns ALL of main's rhythm. The band carries the wizard's identity;
      the step cards keep their <.card> surface (the grammar's card
      already). --%>
      <div class="appgram contents">
        <%!-- 1. The sunken band: back link, mono eyebrow (Deploy), the
        app's name on the working-page scale, and the stepper in the
        working register (core_components' stepper — shared with the
        top-up wizard; token-level restyle there). --%>
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <.button variant="ghost" size="sm" navigate={~p"/apps/#{@app.slug}"} class="-ml-2">
                &larr; {@app.name}
              </.button>

              <p class="eyebrow mt-4">Deploy</p>
              <%!-- The visible "Deploy" prefix stays in the h1: without it,
              this page's heading outline reads identically to the app
              detail page's (hostile-348 F9). The prefix is quieter; the
              app name carries the page-title treatment. --%>
              <h1 class="page-title mt-1">
                <span class="mr-1.5 text-2xl font-semibold tracking-tight text-ink-muted">
                  Deploy
                </span>
                {@app.name}
              </h1>

              <div class="mt-6">
                <.stepper
                  steps={[
                    {"version", "Version"},
                    {"configuration", "Configuration"},
                    {"resources", "Resources"},
                    {"name", "Name"}
                  ]}
                  current={@step - 1}
                />
              </div>

              <%!-- The org context (#408): where this instance lands. A
              native select — one control, no dropdown chrome to manage;
              the wizard's own band is the only surface that needs it.
              Hidden when the actor resolves no orgs at all (the seeded
              shape — the create keeps its personal-org default).

              The wrapping form is load-bearing, not layout: phx-change
              is a FORM binding — on the bare select no change event
              ever reached the server (the picker looked picked in the
              DOM while the create kept the personal-org default;
              found from the browser while capturing #597 S3 — the
              channel-level tests bypass the DOM binding, so only a
              real browser trips it). --%>
              <form
                :if={@org_options != []}
                id="deploy-org-form"
                phx-change="pick-org"
                class="mt-4 flex items-center gap-3"
              >
                <label for="deploy-org" class="text-sm text-ink-muted">
                  Deploy to
                </label>
                <select
                  id="deploy-org"
                  name="org_id"
                  data-testid="deploy-org-picker"
                  class="rounded-lg border border-line bg-panel px-2.5 py-1.5 text-sm text-ink outline-offset-2 outline-focus transition-colors hover:bg-panel-raised focus-visible:outline-2"
                >
                  <option :for={org <- @org_options} value={org.id} selected={org.id == @org_id}>
                    {org.name}
                  </option>
                </select>
              </form>
            </div>
          </div>
        </section>

        <%!-- 2. The steps: one card at a time, swapped by LiveView
        patches. The section wrapper's rise is container-level and
        persistent — the wrapper node survives every patch, so the
        animation never replays (a rise on a step card itself would;
        measured in the PR). --%>
        <section class="wrap pt-10 pb-16">
          <div class="rise mx-auto max-w-2xl space-y-8">
            <.card :if={@step == 1} class="space-y-4">
              <h2 class="text-base font-medium text-ink">Pick a version</h2>
              <div class="space-y-2">
                <%!-- No transition utility on the label row: a <label> is
                neither a nor button, so the grammar's reduced-motion
                kill can't reach it — the hover state stays, the motion
                goes (S8's 60ms-sample lesson, same as S7's). --%>
                <label
                  :for={version <- @versions}
                  for={"version-#{version.id}"}
                  class="flex cursor-pointer items-center gap-3 rounded-lg px-3 py-2 hover:bg-panel-raised"
                >
                  <input
                    type="radio"
                    name="version_id"
                    id={"version-#{version.id}"}
                    value={version.id}
                    checked={@version_id == version.id}
                    phx-click="pick-version"
                    phx-value-id={version.id}
                    class="size-4 accent-primary"
                    data-testid="version-option"
                  />
                  <span class="text-sm text-ink">
                    <span class="font-mono">v{version.version}</span>
                    <span :if={version.published_at} class="ml-1 text-xs text-ink-subtle">
                      published {Calendar.strftime(version.published_at, "%b %d, %Y")}
                    </span>
                    <span
                      :if={version.recommended_size}
                      class="ml-1 font-mono text-xs text-ink-subtle"
                      data-testid={"version-price-#{version.version}"}
                    >
                      <%!-- #558: the version's whole recommendation — the
                      compute class plus its own storage default, the
                      same figure the catalog card badge quotes. --%>
                      {version_price(version)}
                    </span>
                  </span>
                </label>
              </div>
              <div class="flex justify-end">
                <.button
                  size="sm"
                  phx-click="to-env"
                  disabled={is_nil(@version_id)}
                  data-testid="continue-version"
                >
                  Continue
                </.button>
              </div>
            </.card>

            <.card :if={@step == 2} class="max-w-lg space-y-4">
              <h2 class="text-base font-medium text-ink">Configuration</h2>

              <%!-- #612 S3: the bundled services own their url_env
              keys, so those inputs never render — the deploy composes
              the values, and a typed one would be refused at create
              (D6). The note says so plainly instead of leaving a
              silent gap in the schema. --%>
              <div
                :if={backing_env_names(@selected) != []}
                id="bundled-env-note"
                data-testid="bundled-env-note"
                class="rounded-xl border border-line bg-panel-raised px-4 py-3 text-sm text-ink"
              >
                <p>
                  {bundled_label(@selected)} run bundled with this app. FluxVale fills in {Enum.join(
                    backing_env_names(@selected),
                    " and "
                  )} automatically at deploy — there's nothing to enter.
                </p>
              </div>

              <%!-- #597 S3: the Pocket ID offer, above the manual env
              form. nil = nothing renders (flag off, no recipe, or no
              active Pocket ID in the target org) — the whole card is
              absent, not collapsed. --%>
              <div :if={@pocketid_offer} id="pocketid-offer" data-testid="pocketid-offer">
                <%= case @pocketid_offer.state do %>
                  <% :offer -> %>
                    <%!-- The working offer: UNTICKED by default (D7).
                    Ticking is the user's explicit yes to the platform
                    creating the client. --%>
                    <div class="rounded-xl border border-primary bg-primary-muted px-4 py-3">
                      <label
                        for="pocketid-offer-check"
                        class="flex cursor-pointer items-start gap-3 text-sm text-ink"
                      >
                        <input
                          type="checkbox"
                          id="pocketid-offer-check"
                          phx-click="toggle-pocketid"
                          checked={@pocketid_ticked}
                          class="mt-0.5 size-4 accent-primary"
                          data-testid="pocketid-offer-check"
                        />
                        <span>
                          <span class="font-medium">
                            Sign in with your Pocket ID — {selected_pocketid_url(
                              @pocketid_offer,
                              @pocketid_instance_id
                            )}
                          </span>
                          FluxVale creates a {@app.name} client named after this instance in your Pocket ID automatically. The manual sign-in inputs stay as the fallback.
                        </span>
                      </label>

                      <%!-- Multiple ready Pocket IDs: pick which one
                      serves the sign-in — a native select riding a
                      form (phx-change is a form binding; the bare
                      select never fires — the org picker's lesson,
                      same fix), most recently deployed first, the
                      default already selected. --%>
                      <div :if={@pocketid_offer.picker?} class="mt-3 flex items-center gap-3 pl-7">
                        <form
                          id="pocketid-picker-form"
                          phx-change="pick-pocketid"
                          class="flex items-center gap-3"
                        >
                          <label for="pocketid-picker" class="text-sm text-ink-muted">
                            Use
                          </label>
                          <select
                            id="pocketid-picker"
                            name="pocketid_id"
                            data-testid="pocketid-picker"
                            class="rounded-lg border border-line bg-panel px-2.5 py-1.5 text-sm text-ink outline-offset-2 outline-focus transition-colors hover:bg-panel-raised focus-visible:outline-2"
                          >
                            <option
                              :for={pocketid <- @pocketid_offer.ready}
                              value={pocketid.id}
                              selected={pocketid.id == @pocketid_instance_id}
                            >
                              {pocketid.name} — {pocketid.url}
                            </option>
                          </select>
                        </form>
                      </div>

                      <%!-- The tick's consequence, named: what hides
                      and what the platform does at deploy (S4). --%>
                      <p
                        :if={@pocketid_ticked}
                        id="pocketid-offer-confirmed"
                        data-testid="pocketid-offer-confirmed"
                        class="mt-2 pl-7 text-xs text-ink-muted"
                      >
                        FluxVale wires sign-in when you deploy. The manual inputs below are hidden for now.
                      </p>
                    </div>
                  <% :mid_setup -> %>
                    <%!-- 204 from the probe: the admin account is still
                    unclaimed — the Pocket ID can't host clients yet. --%>
                    <div
                      id="pocketid-mid-setup"
                      data-testid="pocketid-mid-setup"
                      class="rounded-xl border border-line bg-panel-raised px-4 py-3 text-sm text-ink"
                    >
                      <p class="font-medium">Finish setting up your Pocket ID first</p>
                      <p class="mt-0.5 text-ink-muted">
                        Its admin account isn't claimed yet, so it can't sign anyone in. Configure sign-in manually below, or come back after setup.
                      </p>
                      <.link
                        navigate={~p"/instances/#{@pocketid_offer.link_instance_id}"}
                        class="mt-1.5 inline-block font-medium text-link hover:underline"
                        data-testid="pocketid-mid-setup-link"
                      >
                        Open your Pocket ID
                      </.link>
                    </div>
                  <% :no_custody -> %>
                    <%!-- Active Pocket ID but no verified API key held:
                    the one-time owner act that unlocks the automatic
                    wiring (S2's card lives on the instance page). --%>
                    <div
                      id="pocketid-no-custody"
                      data-testid="pocketid-no-custody"
                      class="rounded-xl border border-line bg-panel-raised px-4 py-3 text-sm text-ink"
                    >
                      <p class="font-medium">One-time: let FluxVale manage sign-in clients</p>
                      <p class="mt-0.5 text-ink-muted">
                        Paste a Pocket ID admin API key once and FluxVale can wire sign-in for your apps automatically. Or configure it manually below.
                      </p>
                      <.link
                        navigate={~p"/instances/#{@pocketid_offer.link_instance_id}"}
                        class="mt-1.5 inline-block font-medium text-link hover:underline"
                        data-testid="pocketid-no-custody-link"
                      >
                        Open your Pocket ID
                      </.link>
                    </div>
                  <% :unreachable -> %>
                    <%!-- Honest degradation (D3): the wizard works, the
                    offer doesn't — the manual inputs are right below. --%>
                    <div
                      id="pocketid-unreachable"
                      data-testid="pocketid-unreachable"
                      class="rounded-xl border border-warning bg-warning-muted px-4 py-3 text-sm text-ink"
                    >
                      <p class="font-medium">Pocket ID not reachable right now</p>
                      <p class="mt-0.5 text-ink-muted">
                        We couldn't check whether it's ready for automatic sign-in. Configure manually below, or start the wizard again in a moment.
                      </p>
                    </div>
                <% end %>
              </div>

              <%!-- The error shape here is map-level (every message hangs
              off the :env_vars attribute — no per-env-name attribution
              exists to wire aria-invalid/aria-describedby against), so
              the honest minimum is the alert region itself: role=alert
              announces the list on mount, and the colocated hook moves
              focus to it (the S8 a11y follow-up; per-field wiring is
              the declared residual). A div, not a ul: alert is not a
              conforming role for ul (hostile-357 F5). --%>
              <div
                :if={env_errors(@form) != []}
                id="env-errors"
                role="alert"
                tabindex="-1"
                phx-hook=".FocusOnMount"
                class="space-y-1 text-sm text-danger focus:outline-none"
              >
                <p :for={msg <- env_errors(@form)}>{msg}</p>
              </div>

              <script :type={Phoenix.LiveView.ColocatedHook} name=".FocusOnMount">
                export default {
                  mounted() {
                    requestAnimationFrame(() => this.el.focus())
                  },
                }
              </script>

              <p :if={@visible_schema == []} class="text-sm text-ink-muted">
                Nothing to configure for this app. Continue.
              </p>

              <form
                :if={@visible_schema != []}
                id="env-form"
                phx-submit="env-continue"
                class="space-y-4"
              >
                <div :for={{name, spec} <- @visible_schema}>
                  <label class="mb-1.5 block text-sm font-medium text-ink" for={"env-#{name}"}>
                    {spec.label}
                    <span :if={spec.required} class="text-danger">*</span>
                    <span class="ml-1 font-mono text-xs text-ink-subtle">{name}</span>
                  </label>
                  <.env_input
                    name={"env_values[#{name}]"}
                    id={"env-#{name}"}
                    spec={spec}
                    value={Map.get(@env_values, name)}
                  />
                  <p :if={spec.description} class="mt-1.5 text-xs text-ink-subtle">
                    {spec.description}
                  </p>
                </div>
                <div class="flex justify-end gap-3 pt-2">
                  <.button variant="ghost" size="sm" type="button" phx-click="back-version">
                    Back
                  </.button>
                  <.button type="submit" size="sm" data-testid="continue-env">
                    Continue
                  </.button>
                </div>
              </form>

              <div :if={@visible_schema == []} class="flex justify-end gap-3">
                <.button variant="ghost" size="sm" type="button" phx-click="back-version">
                  Back
                </.button>
                <.button type="button" size="sm" phx-click="env-continue" data-testid="continue-env">
                  Continue
                </.button>
              </div>
            </.card>

            <.card :if={@step == 3} class="space-y-4">
              <h2 class="text-base font-medium text-ink">Resources</h2>

              <p class="text-sm text-ink-muted">
                {@app.name} recommends
                <span
                  class="font-mono text-ink"
                  data-testid="recommended-allocation"
                >
                  {@selected.default_cpu_cores} CPU · {@selected.default_memory_mb} MB compute and {@selected.default_storage_gb} GB storage
                </span>
                <%= if @selected.backing_services == [] do %>
                  for this version. Allocate more, or less at your own risk.
                <% else %>
                  for this version.
                <% end %>
              </p>

              <%!-- #612 S3 (ADR-0045 D1/D4/D5): the honest-share
              disclosure. The bundled services are purchased workload
              carved from this allocation, not overhead on top — so
              the same allocation carries them, and it can't go
              lower. --%>
              <div
                :if={@selected.backing_services != []}
                id="bundled-services-note"
                data-testid="bundled-services-note"
                class="rounded-xl border border-line bg-panel-raised px-4 py-3 text-sm text-ink"
              >
                <p>
                  <span class="font-medium">Includes {bundled_label(@selected)}.</span>
                  They run inside the instance and share its CPU, memory, and storage. That sets the smallest allocation here — smaller would starve them.
                </p>
              </div>

              <form
                id="resources-form"
                phx-change="resources-change"
                phx-submit="resources-continue"
                class="space-y-5"
              >
                <div class="space-y-2">
                  <p class="text-sm font-medium text-ink" id="quick-picks-label">Quick picks</p>
                  <div
                    class="grid gap-2 sm:grid-cols-2"
                    role="group"
                    aria-labelledby="quick-picks-label"
                  >
                    <button
                      :for={preset <- @presets}
                      type="button"
                      id={"preset-#{preset.slug}"}
                      phx-click="pick-size"
                      phx-value-slug={preset.slug}
                      aria-pressed={preset.pressed}
                      data-testid={"preset-#{preset.slug}"}
                      class={[
                        "flex items-center justify-between gap-3 rounded-lg border px-3 py-2 text-left transition-colors",
                        "outline-offset-2 outline-focus focus-visible:outline-2",
                        if(preset.pressed == "true",
                          do: "border-primary bg-primary-muted",
                          else: "border-line bg-panel hover:border-line-strong hover:bg-panel-raised"
                        )
                      ]}
                    >
                      <span class="min-w-0">
                        <span class="block text-sm font-medium text-ink capitalize">
                          {preset.slug}
                          <span
                            :if={preset.recommended}
                            class="ml-1 align-middle rounded-full bg-primary-muted px-1.5 py-0.5 text-[0.6875rem] font-normal text-link"
                          >
                            recommended
                          </span>
                        </span>
                        <span class="block truncate font-mono text-xs text-ink-muted">
                          {preset.allocation}
                        </span>
                      </span>
                      <span class="flex-none text-sm font-semibold text-ink">
                        {preset.price}
                      </span>
                    </button>
                  </div>
                </div>

                <AllocationSliders.sliders resources={@resources} floors={@floors} />

                <.callout
                  :if={@below_recommendation?}
                  id="below-recommendation-warning"
                  tone="warning"
                  role="alert"
                  data-testid="below-recommendation-warning"
                >
                  <p class="font-medium text-ink">
                    This is below what {@app.name} recommends. It may run slowly or fail.
                  </p>
                  <label
                    for="below-recommendation-ack"
                    class="flex cursor-pointer items-center gap-3 pt-2 text-sm text-ink"
                  >
                    <input
                      type="checkbox"
                      name="resources[below_ack]"
                      id="below-recommendation-ack"
                      checked={@below_ack}
                      class="size-4 accent-warning"
                      data-testid="below-recommendation-ack"
                    /> I understand, deploy with less than the recommended resources
                  </label>
                </.callout>

                <div
                  class="flex flex-wrap items-center justify-between gap-4 rounded-xl bg-panel-raised px-4 py-3 text-sm"
                  data-testid="resources-price"
                >
                  <span class="text-ink">
                    {@app.name} <span class="font-mono">v{@selected.version}</span>
                    <span :if={@resources} class="text-ink-muted">
                      · {allocation_text(@resources)}
                    </span>
                  </span>
                  <.price_line selected={@selected} resources={@resources} />
                </div>

                <div class="flex justify-end gap-3 pt-2">
                  <.button variant="ghost" size="sm" type="button" phx-click="back-env">
                    Back
                  </.button>
                  <.button
                    type="submit"
                    size="sm"
                    disabled={@below_recommendation? and not @below_ack}
                    data-testid="continue-resources"
                  >
                    Continue
                  </.button>
                </div>
              </form>
            </.card>

            <.card :if={@step == 4} class="space-y-4">
              <h2 class="text-base font-medium text-ink">Name your instance</h2>
              <div
                :if={@selected}
                class="flex flex-wrap items-center justify-between gap-4 rounded-xl bg-panel-raised px-4 py-3 text-sm"
                data-testid="price-summary"
              >
                <%!-- The confirm step's figures ride the mono register (the
                wizard's one technical readout outside the resources
                step). --%>
                <span class="text-ink">
                  {@app.name} <span class="font-mono">v{@selected.version}</span>
                  <span :if={@resources} class="font-mono text-ink-muted">
                    · {allocation_text(@resources)}
                  </span>
                </span>
                <.price_line selected={@selected} resources={@resources} />
              </div>
              <%!-- Same a11y posture as the env step's list: the alert
              region takes focus on mount (this is the arm a failed
              save lands on when the errors render here). Div, not ul —
              hostile-357 F5. --%>
              <div
                :if={step_invisible_errors(@form) != []}
                id="deploy-errors"
                role="alert"
                tabindex="-1"
                phx-hook=".FocusOnMount"
                class="space-y-1 text-sm text-danger focus:outline-none"
              >
                <p :for={msg <- step_invisible_errors(@form)}>{msg}</p>
              </div>
              <.form for={@form} id="deploy-form" phx-submit="save" class="space-y-4">
                <.input
                  field={@form[:name]}
                  type="text"
                  label="Instance name"
                  placeholder={"My #{@app.name}"}
                  required
                  autofocus
                  data-testid="instance-name"
                />
                <p class="text-xs text-ink-subtle">
                  We'll generate the subdomain. The name is yours to change later, nothing else.
                </p>
                <div class="flex justify-end gap-3 pt-2">
                  <.button variant="ghost" size="sm" type="button" phx-click="back-resources">
                    Back
                  </.button>
                  <.button
                    type="submit"
                    phx-disable-with="Deploying…"
                    data-testid="deploy-submit"
                  >
                    Deploy {@app.name}
                  </.button>
                </div>
              </.form>
            </.card>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # The price line is one component so the resources step and the name
  # step can't disagree. The estimate follows the allocation (#186,
  # #558's split axes): at the recommended compute it is the size's
  # compute rate plus the storage axis at the chosen rung — moving
  # only storage walks the axis, never the custom-allocation formula;
  # custom compute prices the whole allocation by the anchor formula —
  # the same cents the ledger snapshots at create, so the shown price
  # is the charged price by construction.
  defp price_line(%{selected: selected, resources: resources} = assigns) do
    at_recommendation = recommendation?(selected, resources)

    assigns =
      assign(assigns,
        at_recommendation: at_recommendation,
        recommended_cents: recommended_cents(selected, resources, at_recommendation),
        custom_cents: custom_allocation_cents(resources, at_recommendation)
      )

    ~H"""
    <span :if={not is_nil(@recommended_cents)} class="font-semibold text-ink">
      {FluxVale.Pricing.format_monthly_rate(@recommended_cents)}
    </span>
    <span :if={not @at_recommendation and not is_nil(@custom_cents)} class="font-semibold text-ink">
      {FluxVale.Pricing.format_monthly_rate(@custom_cents)}
    </span>
    """
  end

  # The at-recommendation rate (#558): the size row prices compute
  # only, so the storage axis at the user's chosen rung completes it —
  # the same split the ledger snapshots (PricingSnapshot), so storage
  # moves the shown price by the axis delta alone. The nil guards
  # (sizeless version, nil resources) mirror recommendation?/2's
  # defensive clause — no render reaches them, and nothing shows
  # rather than a guess.
  defp recommended_cents(_selected, _resources, false), do: nil

  defp recommended_cents(selected, resources, true) do
    size = selected.recommended_size

    if size && resources do
      storage_gb = allocation(resources).storage_gb
      size.monthly_cents + FluxVale.Pricing.storage_monthly_cents(storage_gb)
    end
  end

  defp custom_allocation_cents(_resources, true), do: nil

  defp custom_allocation_cents(resources, false) do
    current = allocation(resources)
    rates = FluxVale.Pricing.price_allocation(current)
    rates.monthly_cents
  end

  # The env surface is a map attribute, not a nested form: plain fields
  # under env_values[NAME] arrive as a map on submit. Values are strings
  # end to end (the K8s Secret's exact contents). Controls ride the
  # system's <.input> (no form field — name/value/explicit attrs, #178
  # wave 2); the label + description stay bespoke (spec metadata).
  defp env_input(%{spec: %{type: :boolean}} = assigns) do
    ~H"""
    <.input
      id={@id}
      name={@name}
      type="select"
      options={[{"true", "true"}, {"false", "false"}]}
      value={value(@spec, @value)}
      class="max-w-xs"
    />
    """
  end

  defp env_input(%{spec: %{type: :integer}} = assigns) do
    ~H"""
    <.input
      id={@id}
      name={@name}
      type="number"
      step="1"
      value={value(@spec, @value)}
      class="max-w-xs"
    />
    """
  end

  defp env_input(assigns) do
    ~H"""
    <.input
      id={@id}
      name={@name}
      type={input_type(@spec)}
      value={value(@spec, @value)}
      class="max-w-xs"
    />
    """
  end

  defp value(_spec, value) when is_binary(value), do: value
  defp value(spec, nil), do: spec.default && to_string(spec.default)

  defp input_type(%{secret: true}), do: "password"
  defp input_type(_spec), do: "text"

  defp env_errors(form) do
    form
    |> AshPhoenix.Form.errors(format: :simple)
    |> Keyword.get_values(:env_vars)
  end

  # Everything the create can reject that the name step renders no
  # input for (#175): :name errors already show on its own input, and
  # :env_vars/:app_version_id bounce back to their steps — the rest
  # (Oct 20's shape: a missing Cluster row erroring on :cluster_id)
  # used to vanish entirely.
  defp step_invisible_errors(form) do
    form
    |> AshPhoenix.Form.errors(format: :simple)
    |> Keyword.drop([:name, :env_vars, :app_version_id])
    |> Keyword.values()
  end

  # --- the Pocket ID SSO offer (#597 S3) -------------------------------------
  # State machine: flag + recipe + active Pocket ID in the target org
  # → probe the custody-ready ones → one of four card states. nil =
  # nothing renders. The probe answers cache per Pocket ID instance
  # for the wizard's life; detection and custody re-read per recompute
  # (cheap org-scoped DB reads — the org picker can move the target).

  defp assign_pocketid_offer(socket) do
    {offer, probes} = pocketid_offer(socket)

    socket
    |> assign(:pocketid_probes, probes)
    |> assign(:pocketid_offer, offer)
    |> assign(:pocketid_ticked, @pocketid_offer_default_unticked)
    |> assign(:pocketid_instance_id, default_pocketid_id(offer))
  end

  # The flag is fail-closed and checked FIRST: off means no reads and
  # no probes at all — prod (unseeded) never touches a Pocket ID.
  defp pocketid_offer(socket) do
    probes = socket.assigns.pocketid_probes
    version = socket.assigns.selected

    cond do
      not FeatureFlags.enabled?(:pocketid_sso_wiring) ->
        {nil, probes}

      is_nil(version.oidc_wiring) ->
        {nil, probes}

      # Seeded/legacy shape: an actor with no resolvable orgs (see
      # default_org_id/2) — no sign-in path produces it, and there is
      # no org to detect Pocket IDs in.
      # coveralls-ignore-next-line
      is_nil(socket.assigns.org_id) ->
        {nil, probes}

      true ->
        org_pocketid_offer(socket)
    end
  end

  # The target org's offer. Active Pocket IDs first (the detection
  # read, §4.1's one query); an empty answer is the card's own absence
  # — an org without a Pocket ID sees nothing at all.
  defp org_pocketid_offer(socket) do
    org_id = socket.assigns.org_id
    user = socket.assigns.current_user

    active = Instance.list_active_pocket_ids_for_organization!(org_id, actor: user)

    if active == [] do
      {nil, socket.assigns.pocketid_probes}
    else
      # S2's seam: the org's custody rows, member-scoped by the read
      # policy (for_organization — built for this detection read).
      custodies = PocketIdCustody.for_organization!(org_id, actor: user)
      ready = Enum.filter(active, &custody_ready?(&1, custodies))
      {probes, completed} = probe_pocketids(socket.assigns.pocketid_probes, ready)

      {offer_state(active, ready, completed, probes), probes}
    end
  end

  # Custody ready = a row for (org, instance) whose ref and
  # verification both stand. The resource holds both not-null by
  # contract (a row exists only once its key verified live), so the
  # checks read degenerate today — kept explicit so a future shape
  # relaxing verification fails the offer closed, not silently.
  defp custody_ready?(instance, custodies) do
    Enum.any?(custodies, fn custody ->
      custody.instance_id == instance.id and not is_nil(custody.api_key_secret_ref) and
        not is_nil(custody.verified_at)
    end)
  end

  # Probe each custody-ready Pocket ID (204 = mid-setup, 404 =
  # completed, anything else = unreachable), caching per instance for
  # the wizard's life — a re-entry or org round trip never re-asks.
  # The ready list is newest-deployed first (the detection read's
  # sort); completed keeps that order — its head is the default pick.
  defp probe_pocketids(cached, ready) do
    probes =
      Enum.reduce(ready, cached, fn instance, probes ->
        Map.put_new_lazy(probes, instance.id, fn ->
          Infrastructure.probe_pocketid_setup(instance)
        end)
      end)

    completed = Enum.filter(ready, &(Map.get(probes, &1.id) == :completed))

    {probes, completed}
  end

  # The four card states, decided in precedence order:
  #
  # - :offer — at least one custody-ready Pocket ID answered completed
  #   (404). The pickable set is the completed ones only: a mid-setup
  #   or unreachable Pocket ID can't host the client.
  # - :no_custody — active Pocket IDs but none custody-ready: the
  #   one-time owner act (S2's intake card) unlocks the offer. Links
  #   the most recently deployed one.
  # - :mid_setup — custody ready but every probed Pocket ID still
  #   answers 204 (admin unclaimed). Links the most recently deployed
  #   mid-setup one.
  # - :unreachable — custody ready, none completed, none mid-setup:
  #   the honest can't-check copy (D3's degrade posture).
  defp offer_state(active, ready, completed, probes) do
    cond do
      completed != [] ->
        %{
          state: :offer,
          ready: Enum.map(completed, &pocketid_option/1),
          picker?: length(completed) > 1,
          link_instance_id: nil
        }

      ready == [] ->
        %{state: :no_custody, ready: [], picker?: false, link_instance_id: hd(active).id}

      Enum.any?(ready, &(Map.get(probes, &1.id) == :mid_setup)) ->
        # The ready list is newest-deployed first; the first mid-setup
        # one is the card's link target.
        mid = Enum.find(ready, &(Map.get(probes, &1.id) == :mid_setup))

        %{state: :mid_setup, ready: [], picker?: false, link_instance_id: mid.id}

      true ->
        %{state: :unreachable, ready: [], picker?: false, link_instance_id: nil}
    end
  end

  defp untick(socket) do
    assign(socket, :pocketid_ticked, false)
  end

  defp tick(socket) do
    recipe_names = recipe_env_names(socket.assigns.selected)
    env_values = Map.drop(socket.assigns.env_values, recipe_names)

    socket
    |> assign(:pocketid_ticked, true)
    |> assign(:env_values, env_values)
  end

  # A picker row / the offer's copy: the Pocket ID instance's id,
  # name, and public URL — the issuer it will answer as (§4.4).
  defp pocketid_option(instance) do
    %{id: instance.id, name: instance.name, url: pocketid_url(instance)}
  end

  # The offer's default pick: the most recently deployed completed
  # Pocket ID (the ready list's head). Non-offer states carry no pick.
  defp default_pocketid_id(%{state: :offer, ready: [first | _rest]}), do: first.id

  defp default_pocketid_id(_offer_or_nil), do: nil

  # The recipe's manual env names — the inputs a ticked offer hides
  # (the platform writes them, #597 §4.2). enabled_env is optional in
  # a recipe; a nil names nothing. The nil clause is defensive: a tick
  # can only exist for a version whose oidc_wiring produced an offer
  # (to-env resets the tick on every version change), so it cannot
  # run in a test.
  # coveralls-ignore-next-line
  defp recipe_env_names(%{oidc_wiring: nil}), do: []

  defp recipe_env_names(%{oidc_wiring: wiring}) do
    names = [
      wiring.issuer_env,
      wiring.client_id_env,
      wiring.client_secret_env,
      wiring.enabled_env
    ]

    Enum.reject(names, &is_nil/1)
  end

  # What the env form renders: the whole schema, minus the recipe's
  # inputs while the offer is ticked, minus a declaring version's
  # platform-owned url_envs — always, not conditionally (#612 S3,
  # D6: the deploy composes those keys, and a typed value would be
  # rejected at create; an unticked (or absent) offer keeps every
  # OTHER input — the manual fallback is always fully rendered).
  defp visible_schema(%{pocketid_ticked: true} = assigns) do
    hidden = recipe_env_names(assigns.selected) ++ backing_env_names(assigns.selected)

    Enum.reject(assigns.schema, fn {name, _spec} -> name in hidden end)
  end

  defp visible_schema(assigns) do
    hidden = backing_env_names(assigns.selected)

    Enum.reject(assigns.schema, fn {name, _spec} -> name in hidden end)
  end

  # The version's platform-owned env keys — the inputs the wizard
  # never renders for a declaring version. nil selected: step 1's
  # render resolves this before any version is picked.
  defp backing_env_names(nil), do: []

  defp backing_env_names(version), do: Enum.map(version.backing_services, & &1.url_env)

  # "PostgreSQL 18 and Redis 8" — the plain-copy spelling, shared by
  # the env note and the resources disclosure (display_name/1's one
  # spelling per kind). Called only where a declaring version is
  # selected (the callers' :if guards).
  defp bundled_label(version) do
    services = version.backing_services

    Enum.map_join(services, " and ", fn service ->
      "#{BackingService.display_name(service.kind)} #{service.version}"
    end)
  end

  # The Pocket ID instance's public URL — the same derivation the
  # deployer seeds APP_URL from (`<slug>.<instances_base_domain>`);
  # no trailing slash (the issuer form the recipe's env expects).
  defp pocketid_url(instance) do
    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)
    "https://#{instance.slug}.#{base_domain}"
  end

  # The offer copy's URL: the chosen Pocket ID's (the default pick,
  # or the picker's selection once it moves).
  defp selected_pocketid_url(%{state: :offer} = offer, selected_id) do
    selected = Enum.find(offer.ready, &(&1.id == selected_id)) || hd(offer.ready)
    selected.url
  end

  @impl Phoenix.LiveView
  def handle_event("pick-version", %{"id" => id}, socket) do
    {:noreply, assign(socket, :version_id, id)}
  end

  # The org context pick (#408). A crafted id: the rendered options
  # can't produce one, so nothing to read and nothing changes — the
  # current pick stays (to-env's guard posture). On step 2 the offer
  # follows the org (#597): a different org's Pocket IDs (or none)
  # recompute the card.
  def handle_event("pick-org", %{"org_id" => org_id}, socket) do
    case Enum.find(socket.assigns.org_options, &(&1.id == org_id)) do
      nil ->
        {:noreply, socket}

      _option ->
        socket = assign(socket, :org_id, org_id)

        socket =
          if socket.assigns.step == 2, do: assign_pocketid_offer(socket), else: socket

        {:noreply, socket}
    end
  end

  def handle_event("to-env", _params, socket) do
    # The Continue button's disabled state is client-side only — a
    # channel-level "to-env" (or a pick of an id not in @versions)
    # must not crash on the nil lookup. Stay on the version step.
    case selected_version(socket) do
      nil ->
        {:noreply,
         socket
         |> assign(:step, 1)
         |> put_flash(:error, "Pick a version first.")}

      version ->
        socket =
          socket
          |> assign(:resources, kept_resources(socket, version))
          |> assign(step: 2, schema: sorted_schema(version), selected: version)
          |> assign_pocketid_offer()
          |> validate_step(%{"app_version_id" => version.id})

        {:noreply, socket}
    end
  end

  def handle_event("back-version", _params, socket) do
    {:noreply, assign(socket, step: 1)}
  end

  def handle_event("env-continue", params, socket) do
    # Crafted before a version is picked: no recommendation to default
    # from (to-env's guard posture — the event can't skip ahead).
    if is_nil(socket.assigns.selected) do
      {:noreply,
       socket
       |> assign(:step, 1)
       |> put_flash(:error, "Pick a version first.")}
    else
      env_continue(params, socket)
    end
  end

  def handle_event("back-env", _params, socket) do
    {:noreply, assign(socket, step: 2)}
  end

  # The offer's tick (#597 D7). Ticking also drops any recipe env
  # values the user had typed: the platform writes those (S4), and a
  # hidden leftover value riding the submit would be the opposite of
  # the platform-injected posture the card promises. Unticking brings
  # the inputs back empty — the manual fallback, honestly blank.
  def handle_event("toggle-pocketid", _params, socket) do
    offer = socket.assigns.pocketid_offer

    socket =
      cond do
        not (is_map(offer) and offer.state == :offer) ->
          # A crafted toggle with no offer on the table (or a non-offer
          # state): nothing to agree to, nothing changes.
          socket

        socket.assigns.pocketid_ticked ->
          untick(socket)

        true ->
          tick(socket)
      end

    {:noreply, socket}
  end

  # Which ready Pocket ID serves the sign-in (the picker's select). A
  # crafted id: the rendered options can't produce one — the pick-org
  # posture, current choice stays.
  def handle_event("pick-pocketid", %{"pocketid_id" => id}, socket) do
    offer = socket.assigns.pocketid_offer

    socket =
      if is_map(offer) and offer.state == :offer and Enum.any?(offer.ready, &(&1.id == id)) do
        assign(socket, :pocketid_instance_id, id)
      else
        socket
      end

    {:noreply, socket}
  end

  # Live: every slider move or preset pick re-renders the
  # below-recommendation warning and keeps the ack coherent (a change
  # that leaves the recommendation band drops a stale ack). A crafted
  # index that names no rung is dropped in AllocationSliders.resource_strings/2, so a
  # partial or hostile payload just keeps the current allocation.
  def handle_event("resources-change", %{"resources" => params}, socket) do
    # Crafted events before a version is picked must not crash on the
    # nil selected version (same posture as to-env's guard); the
    # resources step's own inputs can't fire before it renders.
    if socket.assigns.selected do
      resources = merged_resources(socket, params)

      {:noreply, assign_resource_state(socket, resources, acked?(params))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("resources-continue", %{"resources" => params}, socket) do
    if socket.assigns.selected do
      resources_continue(params, socket)
    else
      {:noreply, put_flash(socket, :error, "Pick a version first.")}
    end
  end

  def handle_event("back-resources", _params, socket) do
    # Step 3 renders the selected version — crafted from before a pick
    # there is nothing to render (to-env's guard posture). A genuine
    # back-nav carries the allocation the env gate set; a crafted one
    # before it gets the recommendation, so the step always renders a
    # full control set (#195) instead of a nil-valued one.
    if socket.assigns.selected do
      resources = socket.assigns.resources || initial_resources(socket.assigns.selected)

      socket =
        socket
        |> assign_resource_state(resources, socket.assigns.below_ack)
        |> assign(:step, 3)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # A quick pick (#195, compute-only since #558): the seeded size's
  # compute at once — the same state the compute sliders would reach —
  # while the storage rung stays the user's (the pick merges over the
  # current allocation, or the recommendation when no state exists
  # yet, so every consumer keeps seeing all three rungs). The ack
  # starts cold: switching allocation always earns a fresh look at the
  # heads-up, and a preset that lands at or above the recommendation
  # never mounts one.
  def handle_event("pick-size", %{"slug" => slug}, socket) do
    if socket.assigns.selected do
      apply_size_pick(socket, slug)
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", %{"instance" => instance_params}, socket) do
    params =
      socket.assigns.form.params
      |> Map.merge(instance_params)
      |> Map.put("env_vars", socket.assigns.env_values)
      |> Map.merge(allocation_params(socket.assigns.resources))
      |> org_param(socket.assigns.org_id)

    form = AshPhoenix.Form.validate(socket.assigns.form, params)

    case AshPhoenix.Form.submit(form, params: params) do
      {:ok, instance} ->
        # Auto-deploy: the stepper's exit is the status page already
        # moving (pending → deploying). The instance page's Deploy
        # button covers the pending/error retry states.
        deploying = Instance.deploy!(instance, actor: socket.assigns.current_user)

        {:noreply,
         socket
         |> put_flash(:info, "Deploying #{deploying.slug}. Tracking its progress.")
         |> push_navigate(to: ~p"/instances/#{deploying.id}")}

      {:error, form} ->
        socket =
          socket
          |> assign(:form, form)
          |> put_flash(:error, "Fix the errors above.")

        # An env error surfacing only at submit (e.g. the schema changed
        # under the stepper) would be invisible on the name step.
        {:noreply, maybe_back_to_env(socket, form)}
    end
  end

  # A version switch resets the allocation (CodeRabbit, #639): the
  # picked rungs belong to the version they were picked for. Carried
  # across a switch they can sit under the new version's floors
  # (#612 S3: an under-floor readout no slider can index, the ack
  # path reopened for a DB entry, a create that can only refuse).
  # Re-entering the SAME version — the back-nav round trip — keeps
  # the choice (the existing pin).
  defp kept_resources(%{assigns: assigns}, %{id: version_id}) do
    case assigns.selected do
      %{id: ^version_id} -> assigns.resources
      _first_pick_or_other_version -> nil
    end
  end

  # The found-size arm, extracted for depth: a known size still has to
  # clear the floors (#612 S3) before it can move the allocation.
  defp apply_size_pick(socket, slug) do
    case Enum.find(socket.assigns.pricing_sizes, &(&1.slug == slug)) do
      nil ->
        # A crafted slug (or a size deleted mid-step): the rendered
        # buttons can't produce one. Nothing to read, nothing changes.
        {:noreply, socket}

      size ->
        pick_floored_size(socket, size)
    end
  end

  defp pick_floored_size(socket, size) do
    floors = resource_floors(socket.assigns.selected)

    if preset_meets_floors?(size, floors) do
      base = socket.assigns.resources || initial_resources(socket.assigns.selected)
      resources = Map.merge(base, size_resources(size))
      {:noreply, assign_resource_state(socket, resources, false)}
    else
      # A crafted pick of an under-floor size (hidden from the
      # rendered buttons, but the channel takes any slug): the create
      # would refuse it, so the pick is silence — the unknown-slug
      # posture.
      {:noreply, socket}
    end
  end

  defp maybe_back_to_env(socket, form) do
    if step_errors?(form, [:env_vars, :app_version_id]) do
      assign(socket, :step, 2)
    else
      socket
    end
  end

  # The create's org context (#408): the picker's pick rides the create
  # argument. No pick means no resolvable orgs — a seeded/legacy shape
  # no sign-in path produces (see default_org_id/2) — and the tenancy
  # change keeps its personal-org default.
  # coveralls-ignore-next-line - seeded/legacy shape, no sign-in path
  defp org_param(params, nil), do: params
  defp org_param(params, org_id), do: Map.put(params, "organization_id", org_id)

  # One option per membership (OrgNav's actor_orgs rides the socket),
  # the personal org labeled as the switcher labels it. Every option is
  # an org the actor belongs to, so the membership fence can never
  # refuse a pick — the wallet gate can (a fresh team org is
  # zero-balance), and that surfaces at submit as the create's
  # Forbidden: the flash copy is the whole message (the Access panel's
  # forbidden? posture — a policy error renders no field input).
  defp org_options(assigns) do
    Enum.map(assigns.actor_orgs, fn membership ->
      %{
        id: membership.organization.id,
        name: org_label(membership.organization, assigns.personal_org_id)
      }
    end)
  end

  defp org_label(org, personal_org_id) when org.id == personal_org_id, do: "Personal"

  defp org_label(org, _personal_org_id), do: org.name

  # The default is the actor's personal org (the create's own default,
  # so the untouched picker changes nothing). The remaining shapes are
  # unreachable for a mounted wizard: a team-org-only actor (no
  # personal org — OrgNav's degraded shape) defaults to their first
  # org, and no orgs at all leaves the create its personal-org default.
  # Both require a signed-in actor with no resolvable personal
  # membership — a seeded/legacy row no sign-in path produces (the JIT
  # provisioning members the creator), so the arms stay as the
  # defensive say.
  # coveralls-ignore-next-line - seeded/legacy shape: no sign-in path
  defp default_org_id([], _personal_org_id), do: nil

  defp default_org_id(options, personal_org_id) do
    if personal_org_id && Enum.any?(options, &(&1.id == personal_org_id)) do
      personal_org_id
    else
      # coveralls-ignore-next-line - seeded/legacy shape: no sign-in path
      hd(options).id
    end
  end

  defp env_continue(params, socket) do
    env_values = drop_empty(params["env_values"] || %{})

    # A back-nav round trip keeps the chosen allocation (env values
    # persist the same way); the ack always starts cold — the warning
    # deserves a fresh look after any detour.
    resources = socket.assigns.resources || initial_resources(socket.assigns.selected)

    socket =
      socket
      |> assign(env_values: env_values, step: 3)
      |> assign_resource_state(resources, false)
      |> validate_step(%{"env_vars" => env_values})

    if step_errors?(socket.assigns.form, [:env_vars, :app_version_id]) do
      socket =
        socket
        |> assign(:step, 2)
        |> put_flash(:error, "Fix the configuration errors below.")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp resources_continue(params, socket) do
    resources = merged_resources(socket, params)
    socket = assign_resource_state(socket, resources, acked?(params))

    if socket.assigns.below_recommendation? and not socket.assigns.below_ack do
      # The disabled button is client-side only — the server-side gate
      # holds for a crafted event (same posture as to-env).
      {:noreply, put_flash(socket, :error, "Acknowledge the below-recommendation warning.")}
    else
      socket =
        socket
        |> validate_step(allocation_params(socket.assigns.resources))
        |> assign(:step, 4)

      {:noreply, socket}
    end
  end

  defp step_errors?(form, fields) do
    errors = AshPhoenix.Form.errors(form, format: :simple)
    Enum.any?(fields, &Keyword.has_key?(errors, &1))
  end

  defp validate_step(socket, extra_params) do
    params = Map.merge(socket.assigns.form.params, extra_params)
    assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))
  end

  defp drop_empty(env_values) do
    env_values
    |> Enum.reject(fn {_name, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp sorted_schema(version) do
    Enum.sort_by(version.configurable_env_vars, fn {_name, spec} -> spec.label end)
  end

  defp selected_version(socket) do
    Enum.find(socket.assigns.versions, &(&1.id == socket.assigns.version_id))
  end

  # --- Resources step (#180) ------------------------------------------------
  # Input state is rung strings end to end (#221): the sliders emit
  # indices, AllocationSliders.resource_strings/2 maps them back to
  # rungs, and nothing off-ladder can enter the state. The form cast
  # on save is the authoritative say.

  # The quick picks (#195): the seeded Sizes, cheapest first — business
  # data (admin-editable, ADR-0027), read once at mount like the rest of
  # the catalog, so an edit lands on the next visit rather than under a
  # wizard already open. Reads are actor-scoped like every other catalog
  # surface. Sizes the sliders can't represent (an admin allocation off
  # the ladder or past a bound) are omitted: a quick pick that its own
  # wizard would refuse or silently clamp is worse than no pick at all.
  defp preset_sizes(user) do
    Size
    |> Ash.Query.for_read(:read, %{}, actor: user)
    |> Ash.Query.sort(monthly_cents: :asc)
    |> Ash.read!()
    |> Enum.filter(&representable_size?/1)
  end

  # A quick pick the compute sliders can state (#221, compute-only
  # since #558): both compute rungs on their ladders — storage never
  # disqualifies a size (the user's own rung rides a pick). An admin
  # compute allocation a rung slider can't express would land as a
  # preset its own wizard refuses or silently clamps: worse than no
  # pick at all, so it stays off the list.
  defp representable_size?(size) do
    size_values = %{
      "cpu_cores" => decimal_string(size.cpu_cores),
      "memory_mb" => Integer.to_string(size.memory_mb)
    }

    dimensions = AllocationSliders.resource_dimensions()

    Enum.all?(size_values, fn {key, value} ->
      dimension = Enum.find(dimensions, &(&1.key == key))
      value in dimension.values
    end)
  end

  # A preset's state contribution (#558): compute rungs only — storage
  # is the user's own axis, so the pick merges over what's already
  # chosen rather than naming a rung.
  defp size_resources(size) do
    %{
      "cpu_cores" => decimal_string(size.cpu_cores),
      "memory_mb" => Integer.to_string(size.memory_mb)
    }
  end

  # The version's whole recommendation (#558): the compute class's rate
  # plus the storage axis at the version's own default — the same
  # figure the catalog card badge quotes. The caller's :if guards the
  # sizeless shape; version_rates/1 prices it.
  defp version_price(version) do
    rates = FluxVale.Pricing.version_rates(version)
    FluxVale.Pricing.format_monthly_rate(rates.monthly_cents)
  end

  # The sub-line under a preset's slug (#558): its compute shape — the
  # price beside it is the compute rate, and storage rides the user's
  # own rung on the axis.
  defp size_allocation(size) do
    "#{decimal_string(size.cpu_cores)} CPU · #{size.memory_mb} MB + your storage"
  end

  # One row per seeded size, resolved once for the template: the slug,
  # the allocation and price it carries, whether it is the version's
  # recommendation, and whether the current allocation IS the size
  # (`aria-pressed` — a string, not a bare boolean, so a screen reader
  # hears the state). DB-backed versions drop under-floor picks
  # (#612 S3): a quick pick its own wizard would refuse (the create's
  # floor validation) is worse than no pick at all — the
  # representable_size?/1 stance, one more filter.
  defp preset_options(assigns) do
    floors = resource_floors(assigns.selected)

    for size <- assigns.pricing_sizes, preset_meets_floors?(size, floors) do
      %{
        slug: size.slug,
        allocation: size_allocation(size),
        price: FluxVale.Pricing.format_monthly_rate(size.monthly_cents),
        recommended: recommended_preset?(assigns.selected, size),
        pressed: to_string(preset_active?(assigns.resources, size))
      }
    end
  end

  # A pick the floors admit: compute at or above the version's RAW
  # defaults — the same bar the create's floor validation enforces
  # (presets are ladder-shaped, so a rung at or above the default and
  # a rung at or above the default's floor rung are the same set).
  # Storage never gates a pick — the user's own rung rides it (#558).
  defp preset_meets_floors?(_size, floors) when map_size(floors) == 0, do: true

  defp preset_meets_floors?(size, floors) do
    cpu_floor = Decimal.new(floors["cpu_cores"])
    memory_floor = String.to_integer(floors["memory_mb"])

    Decimal.compare(size.cpu_cores, cpu_floor) != :lt and size.memory_mb >= memory_floor
  end

  defp recommended_preset?(version, size) do
    not is_nil(version) and not is_nil(version.recommended_size) and
      version.recommended_size.slug == size.slug
  end

  # A preset reads as pressed only when the compute allocation IS the
  # size — same comparison the recommendation check makes, so a
  # repriced or re-allocated size row degrades to "nothing pressed"
  # instead of lying. Storage never unpresses one (#558): it's the
  # user's own axis, not the size's. A nil allocation (any render
  # before the resources step assigns one) is nothing pressed.
  defp preset_active?(nil, _size), do: false

  defp preset_active?(resources, size) do
    current = allocation(resources)

    Decimal.eq?(current.cpu_cores, size.cpu_cores) and
      current.memory_mb == size.memory_mb
  end

  # The app's minimum is the version's defaults (the recommendation).
  # The compute pair equals the recommended size's compute by contract
  # (ValidateSizeMatchesAllocation), so it names a rung; storage is
  # the version's own default and may sit between rungs. When a
  # default doesn't (an admin size the ladder can't express,
  # ADR-0027), the floor still has to be SATISFIABLE: the initial
  # allocation clamps up to the next rung at or above the default, so
  # within the ladder the step never opens under the app's stated
  # minimum. A default PAST the top rung floors to the top rung —
  # which is below the stated minimum, and the heads-up honestly says
  # so: rungs-only simply never offers more (a test pins both).
  defp initial_resources(version) do
    defaults = %{
      "cpu_cores" => decimal_string(version.default_cpu_cores),
      "memory_mb" => Integer.to_string(version.default_memory_mb),
      "storage_gb" => Integer.to_string(version.default_storage_gb)
    }

    dimensions = AllocationSliders.resource_dimensions()

    Map.new(dimensions, fn dimension ->
      {dimension.key, floor_rung(dimension, defaults[dimension.key])}
    end)
  end

  # DB-entry floors (#612 S3, D4/D5): a version bundling backing
  # services never offers a rung below its defaults — the services
  # share the purchased envelope, and the 0-GB storage rung hides
  # with the rest (a DB entry at 0 GB has nowhere to put its data
  # dir). Values are raw defaults (may sit between rungs);
  # AllocationSliders.offered_values/2 floors them onto the ladders.
  # %{} = no floors (every existing entry — behavior unchanged).
  defp resource_floors(nil), do: %{}

  defp resource_floors(%{backing_services: []}), do: %{}

  defp resource_floors(version) do
    %{
      "cpu_cores" => decimal_string(version.default_cpu_cores),
      "memory_mb" => Integer.to_string(version.default_memory_mb),
      "storage_gb" => Integer.to_string(version.default_storage_gb)
    }
  end

  defp floor_rung(dimension, default) do
    floor = Decimal.new(default)

    at_or_above? = fn value ->
      rung = Decimal.new(value)
      Decimal.compare(rung, floor) != :lt
    end

    dimension.values
    |> Enum.find(at_or_above?)
    |> Kernel.||(List.last(dimension.values))
  end

  # A Decimal as a form value: normalized first (so 0.50, 1.0 and 1
  # are one number — the ladder strings are in shortest form, and both
  # the quick-pick membership check and the sliders' index lookup are
  # string comparisons), then expanded (`:normal` undoes the exponent
  # form normalize lowers to — normalize(10) prints "10", never "1E+1").
  defp decimal_string(value) do
    normalized = Decimal.normalize(value)
    Decimal.to_string(normalized, :normal)
  end

  # Partial params merge over the current state — or the
  # recommendation when no allocation state exists yet (a crafted
  # event between the version and env gates), so every consumer always
  # sees all three rungs. Decoded against the FLOORED ladders for a
  # DB-backed version (#612 S3): an index the rendered sliders can't
  # emit can never name an under-floor rung.
  defp merged_resources(socket, params) do
    base = socket.assigns.resources || initial_resources(socket.assigns.selected)

    decoded = AllocationSliders.resource_strings(params, resource_floors(socket.assigns.selected))

    Map.merge(base, decoded)
  end

  # The checkbox rides the form's phx-change; its presence is the state.
  defp acked?(params), do: Map.has_key?(params, "below_ack")

  defp assign_resource_state(socket, resources, acked) do
    version = socket.assigns.selected
    below? = below_recommendation?(resources, version)

    socket
    |> assign(:resources, resources)
    |> assign(:below_recommendation?, below?)
    |> assign(:below_ack, acked and below?)
  end

  # Below the recommendation: any dimension strictly under the version's
  # default.
  defp below_recommendation?(resources, version) do
    current = allocation(resources)

    Decimal.compare(current.cpu_cores, version.default_cpu_cores) == :lt or
      current.memory_mb < version.default_memory_mb or
      current.storage_gb < version.default_storage_gb
  end

  # The typed allocation for the recommendation checks and pricing — a
  # total function since #221: every string the state can hold is a
  # rung, and rungs parse by construction. The form cast on save stays
  # the authoritative say.
  defp allocation(resources) do
    %{
      cpu_cores: Decimal.new(resources["cpu_cores"]),
      memory_mb: String.to_integer(resources["memory_mb"]),
      storage_gb: String.to_integer(resources["storage_gb"])
    }
  end

  # The allocation as form params — strings, cast by the form the same
  # way the save path would cast them.
  defp allocation_params(nil), do: %{}

  defp allocation_params(resources) do
    %{
      "cpu_cores" => resources["cpu_cores"],
      "memory_mb" => resources["memory_mb"],
      "storage_gb" => resources["storage_gb"]
    }
  end

  # nil resources (a channel-level save or crafted nav from before the
  # resources step) read as the recommendation: the derive applies the
  # version defaults. #195 made step 3 assign an allocation on every
  # way in, so no render reaches this — the clause stays as the
  # defensive say for a nil that would otherwise crash allocation/1.
  # coveralls-ignore-next-line — defensive: both step-3 entries assign resources first
  defp recommendation?(_version, nil), do: true

  # At the recommendation = compute dims on the version's defaults
  # (#558): storage is the user's own axis and never defects the
  # compute from its size — the same split PricingSnapshot's
  # custom_allocation? makes, so the shown price and the charged arm
  # agree.
  defp recommendation?(version, resources) do
    current = allocation(resources)

    Decimal.eq?(current.cpu_cores, version.default_cpu_cores) and
      current.memory_mb == version.default_memory_mb
  end

  defp allocation_text(resources) do
    "#{resources["cpu_cores"]} CPU · #{resources["memory_mb"]} MB · #{resources["storage_gb"]} GB"
  end
end
