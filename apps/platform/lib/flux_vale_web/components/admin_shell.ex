defmodule FluxValeWeb.AdminShell do
  @moduledoc """
  The admin console's section sidebar (ADR-0027 Am. 4, #501). Every
  custom /admin surface renders it beside its content, so the console's
  navigation cannot drift between sections — the account-settings
  sidebar's idiom (#568) at admin scope: one shared component, the
  same shape users already know from settings.

  Live sections link to their routes. Every section of the v1 console
  is live, so the Coming badge grammar (the homepage cards' honesty
  grammar, transplanted) retired at the console's completion: an entry
  without a path has no way to render, and a section that is not built
  yet simply has no entry. The deep debugging group keeps the generated
  tools on their demoted subpaths, with copy that says what they are.

  The resource console's navigation is domain-divided (D3 revised,
  2026-11-08): under the Resources group, one collapsible
  `<details>/<summary>` per live registry domain, every registry
  resource a leaf link. The registry drives the nav — pending domains
  render nothing until their slice flips them live. Groups render
  collapsed everywhere except the console surface's own active domain
  (the `open` attribute, so deep links and reloads render right with
  no collapse state to manage). The leaf's aria-current follows the
  page/location grammar; while a leaf is marked, the group's landing
  entry stays quiet — one marked entry per surface.
  """

  use FluxValeWeb, :html

  alias FluxValeWeb.AdminConsole

  attr(:current, :string, required: true, doc: "the active entry's key (see groups/0)")

  attr(:exact, :boolean,
    default: true,
    doc:
      "false when the mounted page is a sub-route of the current section, so the entry marks an ancestor, not the page itself"
  )

  attr(:console, :map,
    default: nil,
    doc:
      "the console surface's nav state, %{domain: key | nil, resource: key | nil, exact: boolean}: the domain whose group renders open, the marked leaf, and whether the leaf's href IS the page. nil (every non-console surface, and the landing) renders all groups collapsed and no leaf marked"
  )

  attr(:pending_requests, :integer,
    default: 0,
    doc:
      "the storage-request queue's pending count, rendered as the Storage requests entry's badge (ADR-0046 D5/D6)"
  )

  @doc """
  The section is the unit of navigation, not the page: a section's
  sub-routes (the sizes ladder, the edit forms) mark the section's
  entry with `aria-current="location"` — an ancestor mark, since
  "page" is reserved for the entry whose href IS the mounted page.
  Every entry carries a path (the Coming grammar retired at the v1
  console's completion); a path-less entry fails the render loudly.
  """
  @spec sidebar(map()) :: Phoenix.LiveView.Rendered.t()
  def sidebar(assigns) do
    unless assigns.current in keys() do
      raise ArgumentError,
            "unknown admin section key #{inspect(assigns.current)} — " <>
              "the valid keys are the entries of AdminShell.groups/0: #{inspect(keys())}"
    end

    # The normalized console nav state: nil on every non-console
    # surface (and the landing), so the template never nil-matches.
    console = assigns[:console] || %{domain: nil, resource: nil, exact: false}

    assigns =
      assign(assigns,
        groups: groups(),
        exact: assigns.exact,
        console: console,
        domains: AdminConsole.domains()
      )

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
            <%!-- The Coming badge grammar retired at the v1 console's
            completion (#501): every entry carries a path. A path-less
            entry fails the render loudly rather than promising quietly.
            The mark rides entry_mark/4 so a console leaf can hand its
            mark to the group's landing entry (D3 revised). --%>
            <.link
              navigate={entry.path}
              aria-current={entry_mark(entry, @current, @exact, @console)}
              class={[
                "border-l-2 py-0.5 pl-3 pr-1 text-sm outline-offset-2 outline-focus focus-visible:outline-2 motion-safe:transition-colors motion-safe:duration-(--motion-fast)",
                entry.key == @current && "border-focus font-medium text-ink",
                entry.key != @current &&
                  "border-transparent text-ink-muted hover:border-line hover:text-ink"
              ]}
              data-testid={"admin-nav-#{entry.key}"}
            >
              <%= if entry.key == "storage-requests" do %>
                <%!-- The queue's live pending count (#250): the badge
                rides the nav's label row, keeping the width budget
                slim — no far-edge float. --%>
                <span class="flex items-center gap-2">
                  {entry.label}
                  <.badge
                    :if={@pending_requests > 0}
                    class="px-1.5! text-[11px]!"
                    aria-label={
                      ngettext(
                        "%{count} pending storage request",
                        "%{count} pending storage requests",
                        @pending_requests
                      )
                    }
                    data-testid="admin-pending-storage-requests"
                  >
                    {@pending_requests}
                  </.badge>
                </span>
              <% else %>
                {entry.label}
              <% end %>
            </.link>
          <% end %>
        </div>
        <%!-- D3 revised: the Resources group's domain sub-groups, the
        registry-driven nav. One disclosure per live domain, every
        registry resource a leaf; the summary is the domain's own
        accessible label. The active domain's group renders open —
        `open` alone (no toggle state), so a deep link or reload
        renders the right shape. --%>
        <div :if={group.key == "resources"} class="mt-2 flex flex-col gap-0.5">
          <details
            :for={domain <- @domains}
            open={@console[:domain] == domain.key}
            class="group"
            data-testid={"admin-sidebar-domain-#{domain.key}"}
          >
            <summary class="cursor-pointer list-none rounded-control border-l-2 border-transparent py-0.5 pl-3 pr-1 text-sm text-ink-muted outline-offset-2 outline-focus transition-colors hover:border-line hover:text-ink focus-visible:outline-2 [&::-webkit-details-marker]:hidden">
              <span class="inline-flex items-center gap-1">
                <.icon
                  name="hero-chevron-right"
                  class="size-3 text-ink-subtle transition-transform group-open:rotate-90"
                />
                {domain.label}
              </span>
            </summary>
            <div class="mt-0.5 flex flex-col items-stretch gap-0.5 pl-3">
              <.link
                :for={resource <- domain.resources}
                navigate={~p"/admin/resources/#{domain.key}/#{resource.key}"}
                aria-current={leaf_mark(resource.key, @console)}
                class={[
                  "border-l-2 py-0.5 pl-3 pr-1 text-sm outline-offset-2 outline-focus focus-visible:outline-2 motion-safe:transition-colors motion-safe:duration-(--motion-fast)",
                  resource.key == @console[:resource] && "border-focus font-medium text-ink",
                  resource.key != @console[:resource] &&
                    "border-transparent text-ink-muted hover:border-line hover:text-ink"
                ]}
                data-testid={"admin-nav-resource-#{domain.key}-#{resource.key}"}
              >
                {leaf_label(resource)}
              </.link>
            </div>
          </details>
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

  # A console leaf is active when the console nav state names it: its
  # href IS the index page (exact) or the surface is one of its
  # sub-routes (show/new/edit) and it marks the ancestor, per the
  # grammar above.
  defp leaf_mark(key, %{resource: key, exact: true}), do: "page"
  defp leaf_mark(key, %{resource: key, exact: false}), do: "location"
  defp leaf_mark(_key, _not_this_surface), do: nil

  # While a leaf is marked, the Resources group's landing entry stays
  # quiet — one marked entry per surface (the open domain group is the
  # ancestor signal, the leaf is the position). Below the leaf level
  # (the landing, the domain page) the landing entry keeps its
  # page/location mark.
  defp entry_mark(_entry, _current, _exact, %{resource: resource}) when not is_nil(resource),
    do: nil

  defp entry_mark(entry, current, exact, _console), do: aria_current(entry.key, current, exact)

  # The leaf label: the registry's config label or the key's own
  # humanized form — the same derivation the domain cards ride.
  defp leaf_label(resource) do
    resource.config[:label] || FluxValeWeb.AdminResource.label(resource.key)
  end

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
          # #501's orgs and instances section: live. The overview and
          # the per-org detail (a sub-route, which marks this entry
          # aria-current="location"). Read-only by design — the v1 plan
          # reserved the section's writes; none are operationally
          # necessary today.
          %{key: "orgs", label: gettext("Orgs and instances"), path: ~p"/admin/orgs"},
          # #250's storage-request queue: a purpose-built workflow
          # section (ADR-0046 D5), not a generic resource leaf. The
          # pending count badges the entry on every admin page.
          %{
            key: "storage-requests",
            label: gettext("Storage requests"),
            path: ~p"/admin/storage-requests"
          },
          # #501's last v1 section: live, read-only by design (the v1
          # plan made gateways/domains oversight; registration and key
          # writes stay on the product surfaces). With this flip every
          # section is live: the Coming badge grammar retired at the
          # console's completion (#501) — every entry carries a path,
          # and a section that is not built yet simply has no entry.
          %{
            key: "gateways",
            label: gettext("Access gateways and domains"),
            path: ~p"/admin/gateways"
          },
          # #645's audit section: the paper trail's window over the
          # business set. The browsable list rides AdminAudit's parity
          # seam with the doctrine gate — the section and the 31
          # cannot drift.
          %{key: "audit", label: gettext("Audit trail"), path: ~p"/admin/audit"}
        ]
      },
      %{
        # The generic resource console (#595, D3 revised 2026-11-08:
        # domain-divided navigation — the landing link below plus the
        # registry-driven domain groups above, never a flat
        # everything-page).
        key: "resources",
        label: gettext("Resources"),
        copy: nil,
        entries: [
          %{key: "resources", label: gettext("Resource console"), path: ~p"/admin/resources"}
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
