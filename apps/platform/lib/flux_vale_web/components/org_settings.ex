defmodule FluxValeWeb.OrgSettings do
  @moduledoc """
  Org settings chrome shared by the tab pages (#276): the identity band
  and the tab nav — every tab page renders both, so no page can drift
  from the tab list.

  S10 (app-wide grammar lane): the header is the cluster's band shell —
  the org home's band posture (eyebrow, page-title name, mono slug) with
  the org mark UNIFIED on the home's row-chip treatment (rounded-panel +
  border-primary/25; the pre-S10 rounded-xl bare chip is retired), and
  the tab rail in the dav-tab register (S3): mono eyebrow-register labels
  on a hairline, the active tab's --focus underline.
  """

  use FluxValeWeb, :html

  attr(:current, :string, required: true, doc: "the active tab's key")
  attr(:slug, :string, required: true)

  @doc """
  One line per tab — the Access tab lands here with its lane. No dead
  tabs ship: the list carries only what exists.
  """
  @spec settings_tabs(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_tabs(assigns) do
    tabs = [
      %{key: "general", label: "General", path: ~p"/organizations/#{assigns.slug}/settings"},
      %{
        key: "members",
        label: "Members",
        path: ~p"/organizations/#{assigns.slug}/settings/members"
      },
      %{
        key: "access",
        label: "Access",
        path: ~p"/organizations/#{assigns.slug}/settings/access"
      }
    ]

    assigns = assign(assigns, :tabs, tabs)

    ~H"""
    <%!-- The dav-tab rail (S3): flex-wrap so the labels always stay
    inside the hairline — at 320px and at text zoom the underline must
    never hang past its rail; below sm the labels trade tracking for
    width. The active tab's underline rides the mode-aware --focus
    token, seated on the rail by the 1px overlap (-mb-px). --%>
    <nav
      class="flex flex-wrap gap-4 border-b border-line"
      aria-label="Organization settings"
      data-testid="org-settings-tabs"
    >
      <.link
        :for={tab <- @tabs}
        navigate={tab.path}
        aria-current={tab.key == @current && "page"}
        class={[
          "-mb-px border-b-2 px-1 pb-2 pt-1.5 font-mono text-xs font-medium uppercase tracking-[0.18em] outline-offset-2 outline-focus focus-visible:outline-2 motion-safe:transition-colors motion-safe:duration-(--motion-fast) max-sm:px-0.5 max-sm:tracking-[0.04em]",
          tab.key == @current && "border-focus text-ink",
          tab.key != @current && "border-transparent text-ink-subtle hover:text-ink-muted"
        ]}
        data-testid={"org-settings-tab-#{tab.key}"}
      >
        {tab.label}
      </.link>
    </nav>
    """
  end

  attr(:org, :map, required: true)

  attr(:surface, :string,
    required: true,
    doc: "the tab page's own eyebrow — Settings / Members / Access"
  )

  @doc """
  The cluster's band shell: the way back, the org identity (mark, name,
  slug) on the org home's band posture, and the page's own surface
  eyebrow. Every tab page renders it, so the org frame cannot drift
  between the tabs.
  """
  @spec org_header(map()) :: Phoenix.LiveView.Rendered.t()
  def org_header(assigns) do
    ~H"""
    <section class="band">
      <div class="wrap pt-8 pb-10">
        <div class="rise">
          <.link
            navigate={~p"/"}
            data-testid="org-back"
            class="inline-flex items-center gap-1.5 text-sm text-ink-muted transition-colors hover:text-ink"
          >
            <span aria-hidden="true">&larr;</span> Dashboard
          </.link>

          <%!-- The mark is the org home's row-chip treatment verbatim —
          the S6 follow-up this slice closes: one org mark app-wide. --%>
          <div class="mt-3 flex min-w-0 items-center gap-4">
            <div
              aria-hidden="true"
              class="grid size-12 shrink-0 place-items-center overflow-hidden rounded-panel border border-primary/25 bg-primary-muted text-lg font-semibold text-link"
            >
              {String.upcase(String.first(@org.name || "?"))}
            </div>
            <div class="min-w-0">
              <p class="eyebrow">Organization</p>
              <h1 class="page-title mt-1.5 truncate" data-testid="org-name">
                {@org.name}
              </h1>
              <p
                class="mt-1.5 truncate font-mono text-sm text-ink-muted"
                data-testid="org-slug"
              >
                {@org.slug}
              </p>
            </div>
          </div>

          <p class="eyebrow mt-7" data-testid="org-surface">{@surface}</p>
        </div>
      </div>
    </section>
    """
  end
end
