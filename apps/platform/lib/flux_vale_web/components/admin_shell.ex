defmodule FluxValeWeb.AdminShell do
  @moduledoc """
  The admin console's section sidebar (ADR-0027 Am. 4, #501). Every
  custom /admin surface renders it beside its content, so the console's
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

  attr(:current, :string, required: true, doc: "the active entry's key (see groups/0)")

  attr(:exact, :boolean,
    default: true,
    doc:
      "false when the mounted page is a sub-route of the current section, so the entry marks an ancestor, not the page itself"
  )

  @doc """
  The section is the unit of navigation, not the page: a section's
  sub-routes (the sizes ladder, the edit forms) mark the section's
  entry with `aria-current="location"` — an ancestor mark, since
  "page" is reserved for the entry whose href IS the mounted page.
  Entries without a `path` render badged and linkless — the badge is
  their whole promise.
  """
  @spec sidebar(map()) :: Phoenix.LiveView.Rendered.t()
  def sidebar(assigns) do
    unless assigns.current in keys() do
      raise ArgumentError,
            "unknown admin section key #{inspect(assigns.current)} — " <>
              "the valid keys are the entries of AdminShell.groups/0: #{inspect(keys())}"
    end

    assigns = assign(assigns, groups: groups(), exact: assigns.exact)

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
        <%!-- The copy is context, not navigation: below md the nav
        stacks over the content, and the debug group's paragraph is the
        block that pushed each surface's primary action under the fold
        (the narrow review) — hidden there, pinned by test. --%>
        <p
          :if={group.copy}
          class="mt-1 max-w-[16rem] text-xs text-ink-subtle hidden md:block"
          data-testid={"admin-sidebar-copy-#{group.key}"}
        >
          {group.copy}
        </p>
        <div class="mt-1 flex flex-col items-stretch gap-0.5 md:mt-2">
          <%= for entry <- group.entries do %>
            <%= if entry[:path] do %>
              <.link
                navigate={entry.path}
                aria-current={aria_current(entry.key, @current, @exact)}
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
              the whole promise, so there is no link to follow. The
              badge rides inline after the label (gap-2), keeping the
              nav's width budget slim — no far-edge float — and rides
              the compact badge treatment (the ! utilities pin it over
              the component's base sizing; the nav is the widest fixed
              cost the content band has). --%>
              <span
                class="flex items-center gap-2 border-l-2 border-transparent py-0.5 pl-3 pr-1 text-sm text-ink-subtle"
                data-testid={"admin-nav-#{entry.key}"}
              >
                {entry.label}
                <.badge class="px-1.5! text-[11px]!" data-testid={"admin-coming-#{entry.key}"}>
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

  # "page" is the HTML spec's mark for the exact current page; a
  # section entry reached from its own sub-route is an ancestor, and
  # the spec's ancestor mark is "location".
  defp aria_current(key, key, true), do: "page"
  defp aria_current(key, key, false), do: "location"
  defp aria_current(_entry_key, _current, _exact), do: nil

  # The console's groups, in the order the lane ships them. Everything
  # with a path exists; everything without is badged Coming.
  defp groups do
    [
      %{
        key: "sections",
        label: gettext("Sections"),
        copy: nil,
        entries: [
          %{key: "people", label: gettext("People and invites"), path: ~p"/admin/people"},
          %{key: "catalog", label: gettext("Catalog and pricing"), path: ~p"/admin/catalog"},
          # #571's wallets and billing section: live. The surface owns
          # the wallet table and the per-wallet detail (a sub-route,
          # which marks this entry aria-current="location").
          %{key: "wallets", label: gettext("Wallets and billing"), path: ~p"/admin/billing"},
          # #501's feedback moderation section: live. The surface owns
          # the posts list, the per-post expansion, and the tag
          # vocabulary.
          %{key: "feedback", label: gettext("Feedback moderation"), path: ~p"/admin/moderation"},
          %{key: "orgs", label: gettext("Orgs and instances")},
          %{key: "gateways", label: gettext("Access gateways and domains")}
        ]
      },
      %{
        key: "deep-debugging",
        label: gettext("Deep debugging"),
        # The generated tools' own pages (AshAdmin, LiveDashboard) carry
        # no shell of their own — they render the generated chrome, so a
        # deep link into them is a nav dead-end until browser-back.
        # Accepted for the debug posture; the breadcrumb-back follow-up
        # is filed (do not build it here).
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

  # The valid `current` keys, derived from the groups so a new entry is
  # automatically addressable and a typo'd key raises at render.
  defp keys do
    groups()
    |> Enum.flat_map(& &1.entries)
    |> Enum.map(& &1.key)
  end
end
