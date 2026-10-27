defmodule FluxValeWeb.OrgSettings do
  @moduledoc """
  Org settings chrome shared by the tab pages (#276). Today that is the
  tab nav — every tab page renders it, so no page can drift from the
  tab list. Later tabs' shared chrome lands here too.
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
      }
    ]

    assigns = assign(assigns, :tabs, tabs)

    ~H"""
    <nav
      class="flex gap-1 border-b border-line"
      aria-label="Organization settings"
      data-testid="org-settings-tabs"
    >
      <.link
        :for={tab <- @tabs}
        navigate={tab.path}
        aria-current={tab.key == @current && "page"}
        class={[
          "-mb-px rounded-t-lg border-b-2 px-3 py-2 text-sm font-medium transition-colors",
          tab.key == @current && "border-primary text-ink",
          tab.key != @current && "border-transparent text-ink-muted hover:text-ink"
        ]}
        data-testid={"org-settings-tab-#{tab.key}"}
      >
        {tab.label}
      </.link>
    </nav>
    """
  end
end
