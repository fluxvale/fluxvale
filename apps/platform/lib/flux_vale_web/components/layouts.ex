defmodule FluxValeWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """

  use FluxValeWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates("layouts/*")

  # Shared chrome pieces (header shell, footer) live here as private
  # components so `app/1` and `public/1` render the same frame — the
  # design system's single nav bar (#178).

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """

  attr(:flash, :map, required: true, doc: "the map of flash messages")

  # Set only by UserAuth's on_mount — the sole resolver of the session
  # into an actor (nil everywhere else, sign-in included).
  attr(:current_user, :map, default: nil)

  # Set only by OrgNav's on_mount — the actor's memberships with the
  # org loaded, the org switcher's rows (#276). LiveViews in the
  # authenticated surface pass it through; everything else renders no
  # switcher rows.
  attr(:actor_orgs, :list, default: [])

  # The active org context (nil = personal) — the closed switcher names
  # it. The org-scoped surfaces pass it; the org billing view (#276) is
  # the first caller.
  attr(:current_org, :map, default: nil)

  slot(:inner_block, required: true)

  def app(assigns) do
    ~H"""
    <.chrome
      flash={@flash}
      current_user={@current_user}
      actor_orgs={@actor_orgs}
      current_org={@current_org}
      apps={true}
    >
      {render_slot(@inner_block)}
    </.chrome>
    """
  end

  @doc """
  Public chrome for the SEO surfaces (#164): logo, Apps, sign-in — or
  the user menu when `MaybeResolveUser` resolved them display-only
  (#205). Mirrors `app/1`'s markup; anonymous visitors have no app
  surface links (Instances/Billing) to show.
  """

  attr(:flash, :map, required: true, doc: "the map of flash messages")

  attr(:current_user, :map, default: nil)

  slot(:inner_block, required: true)

  def public(assigns) do
    ~H"""
    <.chrome flash={@flash} current_user={@current_user} apps={false} footer={true}>
      {render_slot(@inner_block)}
    </.chrome>
    """
  end

  attr(:flash, :map, required: true)
  attr(:current_user, :map, default: nil)
  attr(:actor_orgs, :list, default: [])
  attr(:current_org, :map, default: nil)
  attr(:apps, :boolean, default: false, doc: "show the app-surface links (authenticated chrome)")
  attr(:footer, :boolean, default: false, doc: "render the marketing footer")
  slot(:inner_block, required: true)

  defp chrome(assigns) do
    ~H"""
    <%!-- Border-first depth (#277 T3): a hairline edge over a
    translucent surface — never a heavy shadow. In dark, elevation
    collapses to transparent by design, so the border lifts to
    --line-strong and carries the depth. --%>
    <header class="sticky top-0 z-40 border-b border-line bg-canvas/80 backdrop-blur dark:border-line-strong">
      <div class="mx-auto flex h-14 max-w-5xl items-center justify-between gap-4 px-4 sm:px-6 lg:px-8">
        <%!-- min-w-0: the cluster is a flex child that must be allowed to
        shrink — without it the switcher label's intrinsic width puts the
        header into horizontal scroll (280-336px and 640-642px bands, and
        any real current_org name, #276 review). The shrink is safe only
        because the switcher pill carries no text below lg (see
        org_switcher: at sm the label occluded the first nav link in the
        640-712px band); above lg the label truncates instead. --%>
        <div class="flex min-w-0 items-center gap-6">
          <.link href="/" class="flex w-fit items-center gap-2">
            <img src={~p"/images/logo.svg"} width="26" height="26" alt="FluxVale" />
            <span class="text-sm font-semibold tracking-tight text-ink">FluxVale</span>
          </.link>
          <%!-- #276: the org switcher rides the app chrome only, for a
          signed-in actor, beside the logo left of the nav links. --%>
          <.org_switcher
            :if={@apps and not is_nil(@current_user)}
            orgs={@actor_orgs}
            current_org={@current_org}
          />
        </div>
        <nav aria-label="Primary">
          <ul class="flex items-center gap-1">
            <li :if={@apps} class="hidden sm:block">
              <.nav_link navigate={~p"/apps"}>Catalog</.nav_link>
            </li>
            <li :if={@apps} class="hidden sm:block">
              <.nav_link navigate={~p"/instances"}>Instances</.nav_link>
            </li>
            <li :if={@apps} class="hidden sm:block">
              <.nav_link navigate={~p"/billing"}>Billing</.nav_link>
            </li>
            <li :if={not @apps}>
              <.nav_link navigate={~p"/catalog"}>Apps</.nav_link>
            </li>
            <li><.theme_toggle /></li>
            <%!-- #205: the signed-in chrome is the user menu — the same
            component on app and public chrome; it retires both the
            plain email + sign-out text and the signed-in "Sign in"
            bug (the button now renders only for anonymous visitors).
            app_links folds the header's surface links into the menu
            below sm (#255): the row (logo + links + theme + menu)
            overflows 375px by 133px otherwise, dropdown closed. --%>
            <li :if={@current_user} class="ml-2">
              <.user_menu email={@current_user.email} app_links={@apps} />
            </li>
            <li :if={is_nil(@current_user)} class="ml-1">
              <.button navigate={~p"/sign-in"} size="sm">
                Sign in <span aria-hidden="true">&rarr;</span>
              </.button>
            </li>
          </ul>
        </nav>
      </div>
    </header>

    <main class="mx-auto max-w-5xl px-4 py-10 sm:px-6 lg:px-8">
      {render_slot(@inner_block)}
    </main>

    <footer :if={@footer} class="border-t border-line bg-panel-raised px-4 py-8 sm:px-6 lg:px-8">
      <div class="mx-auto flex max-w-5xl flex-col items-center justify-between gap-4 sm:flex-row">
        <p class="text-sm text-ink-subtle">© {Date.utc_today().year} FluxVale</p>
        <nav aria-label="Footer">
          <ul class="flex items-center gap-4">
            <li>
              <.link navigate={~p"/catalog"} class="text-sm text-ink-muted hover:text-ink">Apps</.link>
            </li>
            <%!-- #205: the footer follows the header's session awareness —
            inward for a session, sign-in for a visitor. --%>
            <li :if={is_nil(@current_user)}>
              <.link navigate={~p"/sign-in"} class="text-sm text-ink-muted hover:text-ink">Sign in</.link>
            </li>
            <li :if={@current_user}>
              <.link navigate={~p"/"} class="text-sm text-ink-muted hover:text-ink">Dashboard</.link>
            </li>
          </ul>
        </nav>
      </div>
    </footer>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      class="flex items-center gap-0.5 rounded-full border border-line bg-panel p-0.5"
      role="group"
      aria-label={gettext("Theme")}
    >
      <button
        class={
          [
            "grid size-7 cursor-pointer place-items-center rounded-full text-ink-subtle transition-colors hover:text-ink-muted",
            # system is active while the source attr says system
            "[[data-theme-source=system]_&]:bg-panel-raised [[data-theme-source=system]_&]:text-ink"
          ]
        }
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label={gettext("Follow system theme")}
      >
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>

      <button
        class={
          [
            "grid size-7 cursor-pointer place-items-center rounded-full text-ink-subtle transition-colors hover:text-ink-muted",
            # explicit picks: data-theme is always set; exclude system mode
            "[[data-theme=light]:not([data-theme-source=system])_&]:bg-panel-raised [[data-theme=light]:not([data-theme-source=system])_&]:text-ink"
          ]
        }
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label={gettext("Light theme")}
      >
        <.icon name="hero-sun-micro" class="size-4" />
      </button>

      <button
        class={[
          "grid size-7 cursor-pointer place-items-center rounded-full text-ink-subtle transition-colors hover:text-ink-muted",
          "[[data-theme=dark]:not([data-theme-source=system])_&]:bg-panel-raised [[data-theme=dark]:not([data-theme-source=system])_&]:text-ink"
        ]}
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label={gettext("Dark theme")}
      >
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end
end
