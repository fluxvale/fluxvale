defmodule FluxValeWeb.AuthLive.InviteAccept do
  @moduledoc """
  The invitee's accept landing (#502, `/invites/accept`): the raw token
  in the query string IS the credential — anonymous by design (the
  invitee has no session yet, acceptance mints one).

  Mount resolves the link's state WITHOUT consuming it and renders
  exactly one row (the org InviteAccept pattern; the state word is the
  whole answer — no email address rides the read, so the page carries
  no PII). Accepting rides the one-shot native form POST to
  SessionController (SignIn's mechanics): the JWT travels in the POST
  body, never a URL, and the invitee lands signed in.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Identity

  # Anonymous surface — outside any live_session — so the locale hook
  # is declared here (SignIn's posture).
  on_mount({FluxValeWeb.Locale, :set_locale})

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <%!-- #502: the auth surface rides Layouts.auth — the mark over the
      panel, SignIn's frame. --%>
      <div class="bg-brand-gradient rounded-panel p-2 shadow-lg">
        <div class="overflow-hidden rounded-panel border border-line-strong bg-panel shadow-sm">
          <div class="space-y-6 p-6 sm:p-8">
            <%= case @state do %>
              <% :pending -> %>
                <div class="space-y-2">
                  <h1 class="text-3xl font-bold tracking-tight text-ink">
                    You're invited
                  </h1>
                  <p class="text-sm leading-6 text-ink-muted" data-testid="invite-accept-note">
                    An account is ready. Accepting signs you in straight away.
                  </p>
                </div>

                <.button
                  phx-click="accept"
                  phx-disable-with="Accepting…"
                  class="w-full"
                  data-testid="invite-accept"
                >
                  Accept and sign in
                </.button>
              <% :accepted -> %>
                <div class="space-y-2">
                  <h1 class="text-3xl font-bold tracking-tight text-ink">
                    Invitation accepted
                  </h1>
                  <p class="text-sm leading-6 text-ink-muted" data-testid="invite-state-copy">
                    This invitation was already accepted.
                  </p>
                </div>
                <.link
                  navigate={~p"/sign-in"}
                  class="text-sm font-medium text-link transition-colors hover:text-link-hover"
                  data-testid="invite-sign-in-link"
                >
                  Sign in instead
                </.link>
              <% :withdrawn -> %>
                <div class="space-y-2">
                  <h1 class="text-3xl font-bold tracking-tight text-ink">
                    Invitation closed
                  </h1>
                  <p class="text-sm leading-6 text-ink-muted" data-testid="invite-state-copy">
                    This invitation is no longer open. Email
                    <.link
                      href="mailto:support@fluxvale.com"
                      class="font-medium text-link underline underline-offset-2 transition-colors hover:text-link-hover"
                      data-testid="invite-support-link"
                    >
                      support@fluxvale.com
                    </.link>
                    if that's a mistake.
                  </p>
                </div>
              <% :expired -> %>
                <div class="space-y-2">
                  <h1 class="text-3xl font-bold tracking-tight text-ink">
                    Invitation expired
                  </h1>
                  <p class="text-sm leading-6 text-ink-muted" data-testid="invite-state-copy">
                    This invitation expired. Ask an admin to send a new one.
                  </p>
                </div>
              <% :unknown_token -> %>
                <div class="space-y-2">
                  <h1 class="text-3xl font-bold tracking-tight text-ink">
                    Invalid link
                  </h1>
                  <p class="text-sm leading-6 text-ink-muted" data-testid="invite-state-copy">
                    This invitation link is not valid.
                  </p>
                </div>
            <% end %>
          </div>
        </div>

        <%!-- The one-shot session POST (SignIn's code-form mechanics):
        the browser fires it when trigger_submit flips, SessionController
        stores the session and lands the invitee signed in. OUTSIDE the
        padded space-y-6 column on purpose: a last child there would
        keep a sibling margin nobody can see (24px of dead card). --%>
        <.form
          for={@form}
          id="session-form"
          action={~p"/auth/session"}
          method="post"
          phx-trigger-action={@trigger_submit}
          class="hidden"
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
          <input type="hidden" name="token" value={@token} />
        </.form>
      </div>
    </Layouts.auth>
    """
  end

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    token = Map.get(params, "token")

    {:ok,
     socket
     |> assign(state: resolve(token), token: token, trigger_submit: false)
     |> assign(form: to_form(%{}))}
  end

  # The page is as strict as its render: the Accept button exists only
  # in the :pending state, so the handler matches that state and any
  # other socket event (a crafted frame from a terminal sentence) is a
  # no-op — the org InviteAccept fence posture.
  @impl Phoenix.LiveView
  def handle_event("accept", _params, %{assigns: %{state: :pending}} = socket) do
    case Identity.accept_invitation(socket.assigns.token) do
      {:ok, _user, jwt} ->
        # The one-shot POST fires: the JWT rides the body to
        # SessionController, never a URL.
        {:noreply, assign(socket, token: jwt, trigger_submit: true)}

      {:error, :not_allowed} ->
        # The account exists but the address can't sign in (the
        # AccessRule gate) — SignIn's explicit copy. The consume already
        # committed, so the row's truth would say :accepted; the flash
        # is the answer here, the state stays as mounted.
        {:noreply,
         put_flash(socket, :error, "That address can't sign in yet. Ask an admin for access.")}

      {:error, _refused} ->
        # The window closed between mount and click (accepted elsewhere,
        # withdrawn, expired) — re-resolve once so the page lands on the
        # row's honest sentence. The assign happens in this single
        # return; nothing re-triggers it.
        {:noreply,
         socket
         |> put_flash(:error, "This invitation can no longer be accepted.")
         |> assign(:state, resolve(socket.assigns.token))}
    end
  end

  def handle_event("accept", _params, socket), do: {:noreply, socket}

  # The read-only resolution: exactly one state renders per row (the
  # org InviteAccept posture). The state word is the whole answer — the
  # email never rides it, so the page renders no PII.
  defp resolve(token) do
    case Identity.resolve_invite_link(token) do
      {:ok, state} -> state
      {:error, :unknown_token} -> :unknown_token
    end
  end
end
