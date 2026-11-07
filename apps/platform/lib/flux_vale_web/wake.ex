defmodule FluxValeWeb.Wake do
  @moduledoc """
  The transport half of the two wake surfaces (#203, ADR-0036 and
  #273, ADR-0039 §6): the interstitial page, the HTML negotiation and
  the status/redirect responses.

  `EdgeWakeController` and `AccessWakeController` keep their own status
  decision tables (the public edge redirects on `:running`, the access
  edge never redirects) and their own view modules. Only this layer is
  shared, so the response bytes cannot fork between them.

  Every helper takes the caller's `view` (and refresh seconds) because
  Phoenix resolves a template through the view module, and the two
  surfaces own different template modules.
  """

  @doc """
  The waking arm: browsers watch the interstitial, everything else gets
  the retryable status line. The wake has triggered either way.
  """
  @spec waking_response(Plug.Conn.t(), map(), keyword()) :: Plug.Conn.t()
  def waking_response(conn, instance, opts) do
    if html_client?(conn) do
      wake_page(conn, instance, opts)
    else
      respond(conn, :service_unavailable, "waking up. Retry shortly", opts)
    end
  end

  @doc """
  The interstitial: JS-free and self-contained, a meta refresh polls
  this same URL until the surface answers differently.
  """
  @spec wake_page(Plug.Conn.t(), map(), keyword()) :: Plug.Conn.t()
  def wake_page(conn, instance, opts) do
    conn
    |> Plug.Conn.put_status(:ok)
    |> Phoenix.Controller.put_root_layout(html: false)
    |> Phoenix.Controller.put_layout(false)
    |> Phoenix.Controller.put_format(:html)
    |> Phoenix.Controller.put_view(opts[:view])
    |> Phoenix.Controller.render(:wake,
      refresh_seconds: opts[:refresh_seconds],
      name: instance.name
    )
  end

  @doc """
  A status line with the retry-after hint, or (for `:found`) a redirect
  onto the now-serving app. Only the edge surface redirects: the access
  edge lets serve's own routing answer the next refresh.
  """
  @spec respond(Plug.Conn.t(), atom(), binary() | nil, keyword()) :: Plug.Conn.t()
  def respond(conn, :found = status, body, opts) do
    conn
    |> Plug.Conn.put_resp_header("location", opts[:location])
    |> maybe_html(status, body, opts)
  end

  # A status response with the retry-after hint (3 seconds by default).
  def respond(conn, status, body, opts) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", opts[:retry_after] || "3")
    |> maybe_html(status, body, opts)
  end

  defp maybe_html(conn, status, body, opts) do
    if html_client?(conn) do
      conn
      |> Plug.Conn.put_status(status)
      |> Phoenix.Controller.put_root_layout(html: false)
      |> Phoenix.Controller.put_layout(false)
      |> Phoenix.Controller.put_format(:html)
      |> Phoenix.Controller.put_view(opts[:view])
      |> Phoenix.Controller.render(:status,
        status: status,
        body: body,
        refresh_seconds: opts[:refresh_seconds]
      )
    else
      Plug.Conn.send_resp(conn, status, body || "")
    end
  end

  @doc "True when the client asks for an HTML document (the browser test)."
  @spec html_client?(Plug.Conn.t()) :: boolean()
  def html_client?(conn) do
    accept_headers = Plug.Conn.get_req_header(conn, "accept")
    accept = List.first(accept_headers)

    is_binary(accept) and String.contains?(accept, "text/html")
  end

  @doc "The request's user-agent header, or nil."
  @spec user_agent(Plug.Conn.t()) :: String.t() | nil
  def user_agent(conn) do
    ua_headers = Plug.Conn.get_req_header(conn, "user-agent")
    List.first(ua_headers)
  end
end
