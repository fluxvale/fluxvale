defmodule FluxValeWeb.AuthLive.SignIn do
  @moduledoc """
  Passwordless sign-in (ADR-0003, #21): email → code-sent → code entry.

  The verify step never mints the session inside the LiveView — success
  hands a one-shot native form POST to `SessionController`, so the token
  travels in a POST body (never a URL — the magic-link lesson) and the
  session write happens in a proper Plug world.

  The return path (#462) rides the same discipline: the link in, a
  validated query param at mount, a hidden input in the verify form —
  so the POST body carries it and SessionController can land the
  visitor back where they came from. The controller re-validates; the
  validation here only keeps garbage out of the rendered form.

  #219: every form also carries a native `action`/`method` fallback —
  the resilience track for networks that block the WebSocket handshake
  (and for JavaScript-off browsers). The email form POSTs to
  `SignInController`, which requests the code and lands on `/sign-in/code`
  (this same LiveView, step preselected, the address riding the session —
  never a URL). The verify form POSTs to `SessionController`, which
  accepts the code where the connected flow hands it a minted token. The
  connected experience is unchanged; `assets/js/app.js` lets a fallback
  form submit natively while the socket is down (LiveView's own submit
  handler would otherwise swallow it).
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Identity
  alias FluxValeWeb.AuthFlow
  alias FluxValeWeb.ReturnPath

  # Outside any live_session (anonymous surface), so the locale hook is
  # declared here — the router's :authenticated list doesn't cover this
  # route.
  on_mount({FluxValeWeb.Locale, :set_locale})

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <%!-- #409: the auth surface rides Layouts.auth — the mark over
      the panel, no marketing chrome. T3 (#277): the panel keeps the
      landing hero's gradient mat (the hero-adjacent moment, same rule
      as the hero mock: no text sits on the gradient). --%>
      <div class="bg-brand-gradient rounded-panel p-2 shadow-lg">
        <div class="overflow-hidden rounded-panel border border-line-strong bg-panel shadow-sm">
          <div class="space-y-6 p-6 sm:p-8">
            <div class="space-y-2">
              <h1 class="text-3xl font-bold tracking-tight text-ink">Sign in to FluxVale</h1>
              <p class="text-sm leading-6 text-ink-muted">
                Passwordless. We'll email you a one-time code.
              </p>
            </div>

            <.form
              :if={@step == :email}
              for={@form}
              id="email-form"
              action={~p"/auth/sign-in"}
              method="post"
              phx-submit="request-code"
              data-native-fallback
              class="space-y-4"
            >
              <%!-- #462/#219: the return path rides the POST body in both
              transports — the native fallback never re-emits it into a
              URL of its own. --%>
              <input :if={@return_to} type="hidden" name="return_to" value={@return_to} />
              <.input
                field={@form[:email]}
                type="email"
                label="Email address"
                placeholder="you@example.com"
                required
                autofocus
                data-testid="sign-in-email"
              />
              <%!-- #478, updated by #502: the honest hint, before the
              wall — an admin's invitation creates the account now, and
              the request step stays enumeration-blind (no behavior
              difference reveals whether an address exists or is
              invited). --%>
              <p class="text-xs leading-5 text-ink-muted">
                New accounts start with an invitation. An admin invites
                your address and the email carries the accept link.
              </p>
              <.button
                type="submit"
                class="w-full"
                phx-disable-with="Sending…"
                data-testid="send-code"
              >
                Send code
              </.button>
            </.form>

            <div :if={@step == :code} class="space-y-4">
              <p class="text-sm text-ink-muted">
                We sent a 6-digit code to <span class="break-words font-medium text-ink">{@email}</span>.
                It expires in 10 minutes.
              </p>

              <.form
                for={@form}
                id="code-form"
                action={~p"/auth/session"}
                method="post"
                phx-submit="verify"
                phx-trigger-action={@trigger_submit}
                data-native-fallback
                class="space-y-4"
              >
                <%!-- #219: the native verify carries the address and code
                to SessionController; the connected hand-off still carries
                the minted token (and wins there). --%>
                <input type="hidden" name="email" value={@email} />
                <input :if={@token} type="hidden" name="token" value={@token} />
                <%!-- #462: the return path rides the POST body with the
                token — never re-emitted into a URL by this flow. --%>
                <input :if={@return_to} type="hidden" name="return_to" value={@return_to} />
                <.input
                  field={@form[:code]}
                  type="text"
                  inputmode="numeric"
                  autocomplete="one-time-code"
                  maxlength="6"
                  label="Sign-in code"
                  required
                  autofocus
                  data-testid="sign-in-code"
                />
                <.button
                  type="submit"
                  class="w-full"
                  phx-disable-with="Signing in…"
                  data-testid="verify-code"
                >
                  Verify &amp; sign in
                </.button>
              </.form>

              <%!-- #219: connected keeps the in-place reset; the native
              page's fallback is a plain link (no socket to handle it). --%>
              <button
                :if={@connected}
                phx-click="change-email"
                class="text-sm font-medium text-link transition-colors hover:text-link-hover"
              >
                Use a different email
              </button>
              <a
                :if={!@connected}
                href={ReturnPath.sign_in_path(@return_to)}
                class="text-sm font-medium text-link transition-colors hover:text-link-hover"
              >
                Use a different email
              </a>
            </div>
          </div>
        </div>
      </div>
    </Layouts.auth>
    """
  end

  def mount(params, session, socket) do
    # Local-only at the door (ReturnPath.safe/1): garbage never reaches
    # the rendered form, and SessionController re-validates regardless.
    return_to = ReturnPath.safe(params["return_to"])

    # #219: /sign-in/code is the native request-code endpoint's PRG
    # target. Its address rides the session (never a URL); a direct hit
    # with no pending request has nothing to verify — back to the email
    # step's own URL.
    case {socket.assigns.live_action, session["sign_in_email"]} do
      {:code, email} when is_binary(email) ->
        {:ok, mount_state(socket, :code, email, return_to)}

      {:code, _no_pending_request} ->
        {:ok, redirect(socket, to: ~p"/sign-in")}

      {:email, _no_pending_request} ->
        {:ok, mount_state(socket, :email, nil, return_to)}
    end
  end

  def handle_event("request-code", %{"email" => email}, socket) do
    outcome = Identity.request_auth_code(email)

    case AuthFlow.request_outcome(outcome) do
      {:ok, message} ->
        {:noreply,
         socket
         |> assign(step: :code, email: email)
         |> assign(form: to_form(%{"code" => ""}))
         |> put_flash(:info, message)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("verify", %{"code" => code}, socket) do
    outcome = Identity.verify_auth_code(socket.assigns.email, code)

    case AuthFlow.verify_outcome(outcome) do
      {:ok, _user, token} ->
        {:noreply, assign(socket, token: token, trigger_submit: true)}

      {:code, message} ->
        {:noreply, put_flash(socket, :error, message)}

      {:email, message} ->
        {:noreply,
         socket
         |> assign(step: :email)
         |> assign(form: to_form(%{"email" => socket.assigns.email}))
         |> put_flash(:error, message)}
    end
  end

  def handle_event("change-email", _params, socket) do
    {:noreply,
     socket
     |> assign(step: :email, token: nil, trigger_submit: false)
     |> assign(form: to_form(%{"email" => socket.assigns.email}))}
  end

  defp mount_state(socket, step, email, return_to) do
    form = if step == :code, do: %{"code" => ""}, else: %{"email" => email || ""}

    socket
    |> assign(step: step, email: email, token: nil, trigger_submit: false, return_to: return_to)
    |> assign(form: to_form(form))
    # The native fallback's one markup difference: an anchor instead of
    # the in-place phx-click reset (see render/1).
    |> assign(connected: connected?(socket))
    # An auth surface is noindex (the launch SEO audit gap): the root
    # layout's seo tags render the <meta name="robots"> from this
    # assign — the same key the SeoNoindex plug sets on non-canonical
    # hosts.
    |> assign(robots_noindex: true)
  end
end
