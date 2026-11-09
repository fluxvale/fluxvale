defmodule FluxValeWeb.AccountSettings do
  @moduledoc """
  Account settings chrome shared by the personal settings surfaces (#551):
  the section sidebar. Every account settings surface renders it
  (Settings, the access personal head, DeveloperSettingsLive), so the
  account cluster's navigation cannot drift between them (the
  OrgSettings posture at account scope).

  Sections group the existing surfaces — Account (Profile, Access,
  Developer) and Billing (Wallet). No dead entries ship: Access and
  Billing ride the personal-org gate, since both targets flash and
  navigate away for the seeded/legacy no-org actor (the settings page's
  access card hid on the same condition; BillingLive's mount degrades
  identically). Developer (#635) is ungated: the page is actor-scoped
  and works for every signed-in actor.
  """

  use FluxValeWeb, :html

  attr(:current, :string, required: true, doc: "the active entry's key")
  attr(:personal_org_id, :string, default: nil)

  @doc """
  One entry per surface — Profile, Access, Developer, Wallet — each at
  its own path (the section-per-surface routing shape: org settings'
  tab idiom at account scope, one LiveView per section, no live_action
  tabs). No dead entries ship: the list carries only what exists.
  """
  @spec sidebar(map()) :: Phoenix.LiveView.Rendered.t()
  def sidebar(assigns) do
    assigns = assign(assigns, :sections, sections(assigns.personal_org_id))

    ~H"""
    <nav
      class="flex flex-col gap-4 md:sticky md:top-20 md:self-start md:gap-6"
      aria-label="Account settings"
      data-testid="account-settings-sidebar"
    >
      <div :for={section <- @sections} data-testid={"account-settings-section-#{section.key}"}>
        <%!-- The section label sits in the org rail's register (S10):
        mono uppercase eyebrow, the group's name above its entries. --%>
        <p class="font-mono text-xs font-medium uppercase tracking-[0.18em] text-ink-subtle">
          {section.label}
        </p>
        <div class="mt-1 flex flex-col items-stretch gap-0.5 md:mt-2">
          <.link
            :for={entry <- section.entries}
            navigate={entry.path}
            aria-current={entry.key == @current && "page"}
            class={[
              "border-l-2 py-0.5 pl-3 pr-1 text-sm outline-offset-2 outline-focus focus-visible:outline-2 motion-safe:transition-colors motion-safe:duration-(--motion-fast)",
              entry.key == @current && "border-focus font-medium text-ink",
              entry.key != @current &&
                "border-transparent text-ink-muted hover:border-line hover:text-ink"
            ]}
            data-testid={"account-settings-nav-#{entry.key}"}
          >
            {entry.label}
          </.link>
        </div>
      </div>
    </nav>
    """
  end

  # The org-gated sections: both gated targets flash and navigate away
  # for the seeded/legacy no-org actor — the settings page's access card
  # hid on this exact condition, and BillingLive's mount degrades
  # identically. The gate leaves the no-org sidebar at Profile and
  # Developer (#635: the developer page is actor-scoped, no org at
  # mount, so its entry ships ungated beside Profile).
  defp sections(nil), do: [%{key: "account", label: "Account", entries: [profile(), developer()]}]

  defp sections(_personal_org_id) do
    [
      %{
        key: "account",
        label: "Account",
        entries: [
          profile(),
          %{key: "access", label: "Access", path: ~p"/settings/access"},
          developer()
        ]
      },
      %{
        key: "billing",
        label: "Billing",
        entries: [%{key: "wallet", label: "Wallet", path: ~p"/billing"}]
      }
    ]
  end

  defp profile, do: %{key: "profile", label: "Profile", path: ~p"/settings"}

  defp developer, do: %{key: "developer", label: "Developer", path: ~p"/settings/developer"}
end
