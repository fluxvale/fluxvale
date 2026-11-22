defmodule FluxVale.TestSupport.ChromeProbe do
  @moduledoc """
  Renders `FluxValeWeb.Layouts.app` through real HEEx for chrome tests —
  function components with a required inner_block can't be rendered
  directly (the slot needs the compiled closure), so this probe is the
  parent. It passes `nav_section` through like the real callers do
  (NavSection's on_mount guarantees the assign on the socket), plus
  `bare` for the band-capable lane and `wide` for the console lane
  (#593).
  """

  use Phoenix.Component

  attr(:nav_section, :atom, default: nil)
  attr(:bare, :boolean, default: false)
  attr(:wide, :boolean, default: false)

  def with_section(assigns) do
    ~H"""
    <FluxValeWeb.Layouts.app
      flash={%{}}
      personal_org_id="org_1"
      username="terence"
      nav_section={@nav_section}
      bare={@bare}
      wide={@wide}
    >
      hello
    </FluxValeWeb.Layouts.app>
    """
  end

  # Signed-in chrome: a plain map as current_user (chrome reads the
  # username/primary_email/email trio and is_nil-guards around them,
  # plus platform_role for the Admin row's gate, #551) so the user_menu
  # renders and the folded-row flow is testable without a DB.
  # platform_role rides the map so the gate is testable at both
  # answers — nil and :user stay non-admin, :admin is the door's own
  # answer.
  attr(:nav_section, :atom, default: nil)
  attr(:platform_role, :atom, default: nil)

  def signed_in(assigns) do
    ~H"""
    <FluxValeWeb.Layouts.app
      flash={%{}}
      personal_org_id="org_1"
      username="terence"
      current_user={
        %{
          username: "terence",
          primary_email: nil,
          email: "terence@fluxvale.test",
          platform_role: @platform_role
        }
      }
      nav_section={@nav_section}
    >
      hello
    </FluxValeWeb.Layouts.app>
    """
  end

  # #881: the public chrome probe — the footer lane's contract holder.
  # Layouts.public renders the one public footer structurally (never
  # opt-in), so this probe pins it without a DB. current_user is a
  # plain map or nil, exactly what the chrome reads elsewhere;
  # return_to rides the #462 sign-in link.
  attr(:current_user, :map, default: nil)
  attr(:return_to, :string, default: nil)

  def public(assigns) do
    ~H"""
    <FluxValeWeb.Layouts.public flash={%{}} current_user={@current_user} return_to={@return_to}>
      hello
    </FluxValeWeb.Layouts.public>
    """
  end
end
