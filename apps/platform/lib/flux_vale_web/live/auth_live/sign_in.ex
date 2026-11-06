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
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Identity
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
              phx-submit="request-code"
              class="space-y-4"
            >
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
                phx-submit="verify"
                action={~p"/auth/session"}
                method="post"
                phx-trigger-action={@trigger_submit}
                class="space-y-4"
              >
                <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
                <input type="hidden" name="token" value={@token} />
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

              <button
                phx-click="change-email"
                class="text-sm font-medium text-link transition-colors hover:text-link-hover"
              >
                Use a different email
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.auth>
    """
  end

  def mount(params, _session, socket) do
    # Local-only at the door (ReturnPath.safe/1): garbage never reaches
    # the rendered form, and SessionController re-validates regardless.
    return_to = ReturnPath.safe(params["return_to"])

    {:ok,
     socket
     |> assign(step: :email, email: nil, token: nil, trigger_submit: false, return_to: return_to)
     # An auth surface is noindex (the launch SEO audit gap): the root
     # layout's seo tags render the <meta name="robots"> from this
     # assign — the same key the SeoNoindex plug sets on non-canonical
     # hosts.
     |> assign(robots_noindex: true)
     |> assign(form: to_form(%{"email" => ""}))}
  end

  def handle_event("request-code", %{"email" => email}, socket) do
    case Identity.request_auth_code(email) do
      :ok ->
        {:noreply,
         socket
         |> assign(step: :code, email: email)
         |> assign(form: to_form(%{"code" => ""}))
         |> put_flash(:info, "Code sent. Check your inbox.")}

      {:error, :throttled} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Please wait a minute before requesting another code."
         )}

      {:error, :not_allowed} ->
        # #26: explicit, not enumeration-safe — staging is team-only;
        # uniform messaging is a beta-invite-flow concern, not an M2 one
        {:noreply,
         put_flash(
           socket,
           :error,
           "That address can't sign in yet. Ask an admin for access."
         )}

      {:error, :delivery_failed} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "We couldn't send the email. Please wait a minute, then try again."
         )}

      {:error, :invalid_address} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That doesn't look like an email address. Check it and try again."
         )}
    end
  end

  def handle_event("verify", %{"code" => code}, socket) do
    case Identity.verify_auth_code(socket.assigns.email, code) do
      {:ok, _user, token} ->
        {:noreply, assign(socket, token: token, trigger_submit: true)}

      {:error, :locked_out} ->
        {:noreply,
         socket
         |> assign(step: :email)
         |> assign(form: to_form(%{"email" => socket.assigns.email}))
         |> put_flash(:error, "Too many attempts. Request a fresh code.")}

      {:error, :not_allowed} ->
        # #26: the rule changed after the code was sent — retrying that
        # code can never succeed; back to the email step with the why
        {:noreply,
         socket
         |> assign(step: :email)
         |> assign(form: to_form(%{"email" => socket.assigns.email}))
         |> put_flash(:error, "That address can't sign in yet. Ask an admin for access.")}

      {:error, :invitation_required} ->
        # #478: the invitation wall — the friction point's honest copy,
        # no dead end (the ask sits in the text). The login code burned
        # with the verify, so the retry is a fresh request anyway; back
        # to the email step, their draft intact.
        {:noreply,
         socket
         |> assign(step: :email)
         |> assign(form: to_form(%{"email" => socket.assigns.email}))
         |> put_flash(
           :error,
           "FluxVale is in invitation-only early access. Creating an account needs an " <>
             "invited address. Write to support@fluxvale.com and we'll send you an invite."
         )}

      {:error, :invite_pending} ->
        # #502: the invited account's only door is the emailed accept
        # link — a code verify can never open it. The code burned with
        # the verify, so the retry is a fresh request anyway; back to
        # the email step, their draft intact (the :invitation_required
        # shape).
        {:noreply,
         socket
         |> assign(step: :email)
         |> assign(form: to_form(%{"email" => socket.assigns.email}))
         |> put_flash(
           :error,
           "This address has an invitation waiting. Use the link in the invitation email " <>
             "to accept it."
         )}

      {:error, _reason} ->
        # Uniform message: unknown address and wrong code look identical
        {:noreply, put_flash(socket, :error, "That code didn't match. Try again.")}
    end
  end

  def handle_event("change-email", _params, socket) do
    {:noreply,
     socket
     |> assign(step: :email, token: nil, trigger_submit: false)
     |> assign(form: to_form(%{"email" => socket.assigns.email}))}
  end
end
