defmodule FluxValeWeb.AccountSettings do
  @moduledoc """
  Account settings chrome shared by the personal settings surfaces (#551):
  the section sidebar. Both surfaces render it, so the account cluster's
  navigation cannot drift between them (the OrgSettings posture at
  account scope).

  Sections group the existing surfaces — Account (Profile, Access) and
  Billing (Wallet). No dead entries ship: the Access entry renders only
  for an actor with a personal org (OrgNav's degradation stance, the
  same gate the settings page's access card rides).
  """

  use FluxValeWeb, :html

  attr(:current, :string, required: true, doc: "the active entry's key")
  attr(:personal_org_id, :string, default: nil)

  @doc """
  One entry per surface — Profile, Access, Wallet — each at its own path
  (the section-per-surface routing shape: org settings' tab idiom at
  account scope, one LiveView per section, no live_action tabs). No dead
  entries ship: the list carries only what exists.
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
        <div class="mt-1 flex flex-wrap gap-x-4 gap-y-1 md:mt-2 md:flex-col md:items-stretch md:gap-0.5">
          <.link
            :for={entry <- section.entries}
            navigate={entry.path}
            aria-current={entry.key == @current && "page"}
            class={[
              "border-l-2 py-0.5 pl-3 pr-1 text-sm outline-offset-2 outline-focus focus-visible:outline-2 motion-safe:transition-colors motion-safe:duration-(--motion-fast) max-md:border-l-0 max-md:pl-0",
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

  # The Access entry rides behind the personal-org gate: a member-only
  # actor's target would be a dead-end not-found (the settings page's
  # access card hides on the same condition).
  defp sections(personal_org_id) do
    access_entry =
      if is_nil(personal_org_id) do
        []
      else
        [%{key: "access", label: "Access", path: ~p"/settings/access"}]
      end

    [
      %{
        key: "account",
        label: "Account",
        entries: [%{key: "profile", label: "Profile", path: ~p"/settings"}] ++ access_entry
      },
      %{
        key: "billing",
        label: "Billing",
        entries: [%{key: "wallet", label: "Wallet", path: ~p"/billing"}]
      }
    ]
  end
end
