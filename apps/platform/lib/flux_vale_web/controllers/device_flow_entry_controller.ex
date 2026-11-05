defmodule FluxValeWeb.DeviceFlowEntryController do
  @moduledoc """
  The device flow's verification_uri landing (#362 T3): `GET
  /settings/access/device` bounces to the settings/access panel at the
  Device sign-ins section.

  A controller redirect, not a LiveView — the panel (OrganizationLive
  .Access) is the surface; this route only lands browsers on it. The
  signed-in check reads the same session chain the live_session
  on_mount gate does (UserAuth.resolve_user), so an anonymous visitor
  skips a hop: sign-in first, the panel's own gate would bounce them
  there anyway.
  """

  use FluxValeWeb, :controller

  # The panel address the browser came for — the anonymous sign-in hop
  # carries it as return_to (#462) so verification resumes at the
  # section instead of the default landing. Fragment included: the
  # value is a local path (ReturnPath's guard), the controller
  # re-validates whatever arrives at the session write.
  @panel_path "/settings/access#device-sign-ins"

  def entry(conn, _params) do
    session = get_session(conn)
    session_user = FluxValeWeb.UserAuth.resolve_user(session)

    # Anchor-scoped redirect (the #device-sign-ins fragment): the
    # browser scrolls the section into view on document load — no
    # LiveView plumbing needed for what a fragment already does.
    if session_user do
      redirect(conn, to: @panel_path)
    else
      redirect(conn, to: FluxValeWeb.ReturnPath.sign_in_path(@panel_path))
    end
  end
end
