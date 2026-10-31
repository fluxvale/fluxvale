defmodule FluxValeWeb.PageController do
  use FluxValeWeb, :controller

  # The library-instructed import for controller-rendered LiveViews
  # (Phoenix.LiveView.Controller's docs): the dashboard below is the
  # app's one live_render caller.
  import Phoenix.LiveView.Controller

  alias FluxValeWeb.DashboardLive

  # #205: session-aware root, GitHub-style — anonymous `/` renders the
  # landing dead view (unchanged; crawlers never carry a session, so
  # #164's SEO slice is intact), a resolved session swaps in the
  # dashboard LiveView in place: same URL, no redirect hop. The full
  # conn session rides the live_render — the same map the router hands
  # live_session mounts, so the LiveView's on_mount gate resolves the
  # actor exactly like every authenticated surface.
  def home(conn, _params) do
    case conn.assigns.current_user do
      nil -> landing(conn, nil)
      _user -> dashboard(conn)
    end
  end

  # The landing's signed-in permalink (#205 scope 5): `/about` always
  # renders the marketing page (user-menu chrome when signed in),
  # canonical to `/` so it never competes with the real landing —
  # which itself carries no canonical tag today, unchanged.
  def about(conn, _params), do: landing(conn, "/")

  # :page_title carries the brand because the root layout's <title> swaps
  # its default for this assign — "Managed hosting…" alone would drop
  # "FluxVale" from the tab title. :page_description is the SEO hook; the
  # root layout will render it as a meta tag with the SEO slice (#164).
  defp landing(conn, canonical_path) do
    conn
    |> assign(:canonical_path, canonical_path)
    |> assign(
      :page_title,
      gettext("FluxVale — Managed hosting for open source applications")
    )
    |> assign(
      :page_description,
      gettext(
        "Browse a curated catalog of open source apps, deploy one in minutes, and let FluxVale keep it running for you."
      )
    )
    |> render(:home)
  end

  defp dashboard(conn) do
    conn
    |> assign(:page_title, "FluxVale — Dashboard")
    |> assign(:page_description, "Your instances, balance, and runway at a glance.")
    |> live_render(DashboardLive, session: get_session(conn))
  end
end
