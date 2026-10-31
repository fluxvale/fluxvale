defmodule FluxVale.TestSupport.LocaleProbeLive do
  @moduledoc false

  # Minimal LiveView for the Locale on_mount arm (locale_test.exs):
  # renders the process's current Gettext locale. live_isolated mounts
  # it without a route, and module-level on_mount hooks still run. The
  # router's live_session wiring is declarative — reviewed, not tested.

  use FluxValeWeb, :live_view

  on_mount({FluxValeWeb.Locale, :set_locale})

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div id="locale-probe">{Gettext.get_locale(FluxValeWeb.Gettext)}</div>
    """
  end
end
