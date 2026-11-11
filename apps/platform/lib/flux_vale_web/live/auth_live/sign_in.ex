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
  alias FluxVale.Identity.GoogleOIDC
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
      as the hero panel: no text sits on the gradient). --%>
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
              <%!-- #462/#219: the email form carries the return path in its
              POST body for both transports. The native request's PRG
              puts the validated value in the code page's URL (the same
              query-param convention the #462 sign-in link uses). --%>
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

            <%!-- #642 (plan §3.4): the second door, below the action
            line — either door, one account (admission decides which
            addresses get one). A plain anchor, no JavaScript: the
            no-WebSocket resilience track holds by construction, and
            Google's own page does the authentication. The G mark is
            inline SVG in Google's official colors — no Google script
            ever loads. --%>
            <div :if={@step == :email and @google_available} class="space-y-4">
              <div class="relative" aria-hidden="true" data-testid="google-divider">
                <div class="absolute inset-0 flex items-center">
                  <span class="w-full border-t border-line-strong"></span>
                </div>
                <div class="relative flex justify-center">
                  <span class="bg-panel px-2 text-xs text-ink-muted">or</span>
                </div>
              </div>

              <.button
                href={google_href(@return_to)}
                variant="secondary"
                class="w-full"
                data-testid="google-sign-in"
              >
                <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true" class="shrink-0">
                  <path
                    fill="#4285F4"
                    d="M17.64 9.2045c0-.6381-.0573-1.2518-.1636-1.8409H9v3.4814h4.8436c-.2086 1.125-.8427 2.0782-1.7959 2.7164v2.2581h2.9087c1.7018-1.5668 2.6836-3.874 2.6836-6.615z"
                  />
                  <path
                    fill="#34A853"
                    d="M9 18c2.43 0 4.4673-.806 5.9564-2.1805l-2.9087-2.2581c-.8059.54-1.8368.859-3.0477.859-2.344 0-4.3282-1.5831-5.036-3.7104H.9573v2.3318C2.4382 15.9832 5.4818 18 9 18z"
                  />
                  <path
                    fill="#FBBC05"
                    d="M3.964 8.7104c-.18-.54-.2823-1.1168-.2823-1.7104s.1023-1.1705.2823-1.7104V3.5573H.9573C.3477 4.6023 0 5.7609 0 7s.3477 2.3977.9573 3.4427l3.0067-2.3323z"
                  />
                  <path
                    fill="#EA4335"
                    d="M9 3.5795c1.3214 0 2.5077.4541 3.4405 1.346l2.5808-2.5807C13.4632.3477 11.426 0 9 0 5.4818 0 2.4382 2.0182.9573 5.1168L3.964 7.4491C4.6718 5.3218 6.6559 3.5795 9 3.5795z"
                  />
                </svg>
                Sign in with Google
              </.button>
            </div>

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
                <%!-- #462/#219: the code form carries the return path in
                its POST body — with the minted token on the connected
                hand-off, with the code on the native one. The session
                write redirects to the validated target; a failed verify
                re-links this page with the value, re-validated on every
                hop. --%>
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
    # step's own URL, the validated return path carried along.
    case {socket.assigns.live_action, session["sign_in_email"]} do
      {:code, email} when is_binary(email) ->
        {:ok, mount_state(socket, :code, email, return_to)}

      {:code, _no_pending_request} ->
        {:ok, redirect(socket, to: ReturnPath.sign_in_path(return_to))}

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
    # #642 (D-flag): the Google door renders under the ONE predicate
    # both controller hops gate on — GoogleOIDC.arm_available?/0 (flag
    # row AND credentials), computed once per mount. A DB blip in the
    # flag read must not 500 a previously-static page: fail CLOSED —
    # the button hides, the email door stays exactly as it was (plan
    # §5's no-worse guarantee); the stub-raising test pins it.
    |> assign(google_available: google_available())
    # An auth surface is noindex (the launch SEO audit gap): the root
    # layout's seo tags render the <meta name="robots"> from this
    # assign — the same key the SeoNoindex plug sets on non-canonical
    # hosts.
    |> assign(robots_noindex: true)
  end

  # #642: the rescue is the honest boundary — the flag read rides the
  # DB, and an Ash read failure (a blip) hides the door instead of
  # 500ing the page the email arm has always served.
  defp google_available do
    GoogleOIDC.arm_available?()
  rescue
    _read_failure -> false
  end

  # #642: the anchor carries the validated return target the same way
  # the email form's hidden input does — plain /auth/google otherwise
  # (@return_to is already ReturnPath.safe-validated at mount).
  defp google_href(nil), do: ~p"/auth/google"

  defp google_href(return_to), do: ~p"/auth/google?return_to=#{return_to}"
end
