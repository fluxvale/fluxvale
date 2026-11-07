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

  # Signed-in chrome: a plain map as current_user (chrome reads only
  # username/primary_email/email and is_nil-guards around them) so the
  # user_menu renders and the folded-row flow is testable without a DB.
  attr(:nav_section, :atom, default: nil)

  def signed_in(assigns) do
    ~H"""
    <FluxValeWeb.Layouts.app
      flash={%{}}
      personal_org_id="org_1"
      username="terence"
      current_user={%{username: "terence", primary_email: nil, email: "terence@fluxvale.test"}}
      nav_section={@nav_section}
    >
      hello
    </FluxValeWeb.Layouts.app>
    """
  end
end
