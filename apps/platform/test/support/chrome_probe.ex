defmodule FluxVale.TestSupport.ChromeProbe do
  @moduledoc """
  Renders `FluxValeWeb.Layouts.app` through real HEEx for chrome tests —
  function components with a required inner_block can't be rendered
  directly (the slot needs the compiled closure), so this probe is the
  parent. It passes `nav_section` through like the real callers do
  (NavSection's on_mount guarantees the assign on the socket), plus
  `bare` for the band-capable lane.
  """

  use Phoenix.Component

  attr(:nav_section, :atom, default: nil)
  attr(:bare, :boolean, default: false)

  def with_section(assigns) do
    ~H"""
    <FluxValeWeb.Layouts.app
      flash={%{}}
      personal_org_id="org_1"
      username="terence"
      nav_section={@nav_section}
      bare={@bare}
    >
      hello
    </FluxValeWeb.Layouts.app>
    """
  end
end
