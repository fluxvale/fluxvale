defmodule FluxValeWeb.Locale do
  @moduledoc """
  One locale resolver for every render path — dead views (the plug,
  wired in the `:browser` pipeline) and LiveViews (the `on_mount`, wired
  first on the `:authenticated` live_session) — so the notion cannot
  fork.

  Resolution order (first match wins):

    1. `session["locale"]`, when it is a binary present in
       `Gettext.known_locales(FluxValeWeb.Gettext)`
    2. the app default locale — the backend's configured
       `default_locale` ("en", config.exs)

  Extension points, documented but deliberately NOT wired:

    * a signed-in user preference — a future sign-in writes the same
      session key, so resolution needs no change here
    * Accept-Language negotiation — a future source slots in ahead of
      the default arm

  Nothing user-visible today: the resolved locale is "en" everywhere.
  """

  # Single source of truth: the backend's pinned default in config.exs,
  # read at compile time so resolution never rides process state.
  @default_locale Application.compile_env(
                    :flux_vale,
                    [FluxValeWeb.Gettext, :default_locale],
                    "en"
                  )

  @doc """
  Resolves the locale for a session map — first match wins (moduledoc).
  """
  @spec resolve(map()) :: String.t()
  def resolve(session) do
    requested = Map.get(session, "locale")

    if requested in Gettext.known_locales(FluxValeWeb.Gettext) do
      requested
    else
      @default_locale
    end
  end

  @doc false
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @doc """
  Applies the resolved locale to the render process. Reads the fetched
  session — the `:browser` pipeline runs this plug after `fetch_session`,
  so that order is part of the contract.
  """
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    locale = resolve(Plug.Conn.get_session(conn))
    Gettext.put_locale(FluxValeWeb.Gettext, locale)
    conn
  end

  @doc """
  LiveView arm: mount runs in a fresh process, so the locale is
  re-resolved from the session map and applied there — the plug's
  process-dictionary write never reaches this process.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:set_locale, _params, session, socket) do
    locale = resolve(session)
    Gettext.put_locale(FluxValeWeb.Gettext, locale)
    {:cont, socket}
  end
end
