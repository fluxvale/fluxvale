defmodule FluxValeWeb.AdminShell do
  @moduledoc """
  The admin console's section sidebar (ADR-0027 Am. 4, #501). Every
  /admin surface renders it beside its content, so the console's
  navigation cannot drift between sections — the account-settings
  sidebar's idiom (#568) at admin scope: one shared component, the
  same shape users already know from settings.

  Live sections link to their routes. The not-yet-built workflows are
  honest entries — a Coming badge and no link (the homepage cards'
  honesty grammar, transplanted; the cards themselves are retired).
  The deep debugging group keeps the generated tools on their demoted
  subpaths, with copy that says what they are.
  """

  use FluxValeWeb, :html

  attr(:current, :string, required: true, doc: "the active entry's key")

  @doc """
  The section is the unit of navigation, not the page: a section's
  sub-routes (the sizes ladder, the edit forms) mark the same catalog
  entry the section list does. Entries without a `path` render badged
  and linkless — the badge is their whole promise.
  """
  @spec sidebar(map()) :: Phoenix.LiveView.Rendered.t()
  def sidebar(assigns) do
    assigns = assign(assigns, :groups, groups())

    ~H"""
    <nav
      class="flex flex-col gap-4 md:sticky md:top-20 md:self-start md:gap-6"
      aria-label={gettext("Admin")}
      data-testid="admin-sidebar"
    >
      <div :for={group <- @groups} data-testid={"admin-sidebar-group-#{group.key}"}>
        <%!-- The group label sits in the account-settings sidebar's
        register (#568): mono uppercase eyebrow above its entries. --%>
        <p class="font-mono text-xs font-medium uppercase tracking-[0.18em] text-ink-subtle">
          {group.label}
        </p>
        <p
          :if={group.copy}
          class="mt-1 max-w-xs text-xs text-ink-subtle"
          data-testid={"admin-sidebar-copy-#{group.key}"}
        >
          {group.copy}
        </p>
        <div class="mt-1 flex flex-col items-stretch gap-0.5 md:mt-2">
          <%= for entry <- group.entries do %>
            <%= if entry[:path] do %>
              <.link
                navigate={entry.path}
                aria-current={entry.key == @current && "page"}
                class={[
                  "border-l-2 py-0.5 pl-3 pr-1 text-sm outline-offset-2 outline-focus focus-visible:outline-2 motion-safe:transition-colors motion-safe:duration-(--motion-fast)",
                  entry.key == @current && "border-focus font-medium text-ink",
                  entry.key != @current &&
                    "border-transparent text-ink-muted hover:border-line hover:text-ink"
                ]}
                data-testid={"admin-nav-#{entry.key}"}
              >
                {entry.label}
              </.link>
            <% else %>
              <%!-- A coming entry is an honest placeholder: the badge is
              the whole promise, so there is no link to follow. --%>
              <span
                class="flex items-center justify-between gap-2 border-l-2 border-transparent py-0.5 pl-3 pr-1 text-sm text-ink-subtle"
                data-testid={"admin-nav-#{entry.key}"}
              >
                {entry.label}
                <.badge data-testid={"admin-coming-#{entry.key}"}>
                  {gettext("Coming")}
                </.badge>
              </span>
            <% end %>
          <% end %>
        </div>
      </div>
    </nav>
    """
  end

  # The console's groups, in the order the lane ships them. Everything
  # with a path exists; everything without is badged Coming. The #571
  # slot is next to flip: when wallets and billing merges, give its
  # entry a `path` and the shell links it — no other change.
  defp groups do
    [
      %{
        key: "sections",
        label: gettext("Sections"),
        copy: nil,
        entries: [
          %{key: "people", label: gettext("People and invites"), path: ~p"/admin/people"},
          %{key: "catalog", label: gettext("Catalog and pricing"), path: ~p"/admin/catalog"},
          # #571 rebases onto this shell: add path: ~p"/admin/…" below
          # and the entry flips live.
          %{key: "wallets", label: gettext("Wallets and billing")},
          %{key: "feedback", label: gettext("Feedback moderation")},
          %{key: "orgs", label: gettext("Orgs and instances")},
          %{key: "gateways", label: gettext("Access gateways and domains")}
        ]
      },
      %{
        key: "deep-debugging",
        label: gettext("Deep debugging"),
        copy:
          gettext(
            "The generated tools. They run as trusted superuser without the resource policies. For emergencies and data surgery."
          ),
        entries: [
          %{key: "ash", label: gettext("AshAdmin"), path: ~p"/admin/ash"},
          %{key: "dashboard", label: gettext("LiveDashboard"), path: ~p"/admin/debug/dashboard"}
        ]
      }
    ]
  end
end
