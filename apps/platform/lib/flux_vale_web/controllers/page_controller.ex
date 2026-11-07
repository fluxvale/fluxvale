defmodule FluxValeWeb.PageController do
  use FluxValeWeb, :controller

  # The library-instructed import for controller-rendered LiveViews
  # (Phoenix.LiveView.Controller's docs): the dashboard below is one of
  # the app's two live_render callers (the /pricing calculator is the
  # other, #397).
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
      nil -> landing(conn)
      _user -> dashboard(conn)
    end
  end

  # The landing's signed-in permalink (#205 scope 5): `/about` always
  # renders the marketing page (user-menu chrome when signed in),
  # canonical to `/` — the same self-canonical the landing now carries
  # (the launch SEO audit lean: `/` shipped none, and og:url emits only
  # alongside one) — so both surfaces fold into `/` for crawlers.
  def about(conn, _params), do: landing(conn)

  # :page_title carries the brand because the root layout's <title> swaps
  # its default for this assign — "Managed cloud platform…" alone would drop
  # "FluxVale" from the tab title. :page_description is the SEO hook; the
  # root layout will render it as a meta tag with the SEO slice (#164).
  defp landing(conn) do
    conn
    |> assign(:canonical_path, "/")
    |> assign(
      :page_title,
      gettext("FluxVale, managed cloud platform for open source applications")
    )
    |> assign(
      :page_description,
      gettext(
        "Browse a curated catalog of open source apps, deploy one in minutes, and let FluxVale keep it running for you."
      )
    )
    |> assign(:price_floor_cents, price_floor_cents())
    |> render(:home)
  end

  # The landing pricing band's floor (#396): the ladder floor over the
  # public Size read — Pricing.from_price_cents/0, shared with the
  # catalog cards (#398). The landing (the crawler surface) carries a DB
  # dependency by decision — `read!` 500s where the page previously
  # rendered DB-free. Same failure envelope as CatalogController on the
  # same SEO scope. Revisit trigger: if the landing ever must render
  # during a DB outage.
  defp price_floor_cents, do: FluxVale.Pricing.from_price_cents()

  defp dashboard(conn) do
    conn
    |> assign(:page_title, "FluxVale Dashboard")
    |> assign(:page_description, "Your instances, balance, and runway at a glance.")
    |> live_render(DashboardLive, session: get_session(conn))
  end
end
