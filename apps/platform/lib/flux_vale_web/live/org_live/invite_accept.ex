defmodule FluxValeWeb.OrganizationLive.InviteAccept do
  @moduledoc """
  The invitation landing page (slice 4 of #408, `/invitations/accept`):
  the raw token in the query string is the invitee-side credential —
  signed-in visitors only (the live_session gate; anonymous hits the
  sign-in redirect, and the email names the address to sign in with).

  Mount resolves the token through the domain seam and renders exactly
  one state: an open invite whose address matches the visitor's
  VERIFIED PRIMARY email shows the org and the Accept/Decline pair; an
  open invite for another address explains who it was sent to (no
  membership can ride a mismatched sign-in); accepted, revoked, and
  expired each get one plain sentence; an unknown token says so.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    user = socket.assigns.current_user
    token = Map.get(params, "token")

    state = resolve(token, user)
    {:ok, to_socket(state, socket, token)}
  end

  # The token + identity fences, rendered: resolve_invite answers the
  # token's state; the open arm then asks whether the visitor's
  # verified primary email is the invited one. current_user carries
  # primary_email from the session resolution (UserAuth's one load) —
  # nil folds into the mismatch arm (no verified row, no proof).
  defp resolve(token, user) do
    case Accounts.resolve_invite(token) do
      {:ok, {:open, invite}} ->
        invited = to_string(invite.email)

        if email_matches?(user.primary_email, invited) do
          {:invite_ready, invited, invite}
        else
          {:email_mismatch, invited, invite}
        end

      {:ok, state} when state in [:accepted, :revoked, :expired] ->
        {state, nil, nil}

      {:error, :unknown_token} ->
        {:unknown_token, nil, nil}
    end
  end

  defp email_matches?(primary_email, invited) when is_binary(primary_email) do
    String.downcase(primary_email) == String.downcase(invited)
  end

  defp email_matches?(_no_verified_primary, _invited), do: false

  defp to_socket({state, invited, invite}, socket, token) do
    assign(socket, state: state, invited_email: invited, invite: invite, token: token)
  end

  @impl Phoenix.LiveView
  def handle_event("accept-invite", _params, socket) do
    case Accounts.accept_invite(socket.assigns.token, socket.assigns.current_user) do
      {:ok, _invite} ->
        org = socket.assigns.invite.organization

        {:noreply,
         socket
         |> put_flash(:info, "You joined #{org.name}.")
         |> push_navigate(to: ~p"/organizations/#{org.slug}")}

      {:error, :already_member} ->
        # The membership exists; the invite row's state is now moot for
        # this visitor — the org home is where they were headed anyway.
        {:noreply, redirect_joined(socket, "You are already a member of this organization.")}

      {:error, _refused} ->
        # The window closed between mount and click (accepted elsewhere,
        # revoked, expired) — the page answers, the row's truth owns it.
        {:noreply, put_flash(socket, :error, "This invitation can no longer be accepted.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("decline-invite", _params, socket) do
    case Accounts.decline_invite(socket.assigns.token) do
      {:ok, _invite} ->
        {:noreply, assign(socket, :state, :declined)}

      {:error, _refused} ->
        {:noreply, put_flash(socket, :error, "This invitation can no longer be declined.")}
    end
  end

  # The raced already-member arm: the operation refused before any
  # fresh read, so the redirect rides the org the mount resolved —
  # it is the row the token named.
  defp redirect_joined(socket, message) do
    org = socket.assigns.invite.organization

    socket
    |> put_flash(:error, message)
    |> push_navigate(to: ~p"/organizations/#{org.slug}")
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      actor_orgs={@actor_orgs}
      personal_org_id={@personal_org_id}
      username={@username}
      nav_section={@nav_section}
      bare
    >
      <div class="appgram contents">
        <section class="wrap pt-8 pb-16">
          <div class="rise mx-auto max-w-xl space-y-6">
            <div class="rounded-panel border border-line-strong bg-panel p-6 shadow-sm sm:p-8">
              <p class="eyebrow">Invitation</p>

              <%= case @state do %>
                <% :invite_ready -> %>
                  <%!-- The invited org and the address the invite names —
                  both visible BEFORE the join, so the accept is an
                  informed click (the data-testids pin the render). --%>
                  <h1 class="page-title mt-2" data-testid="invite-org">
                    {@invite.organization.name}
                  </h1>
                  <p class="mt-3 text-sm text-ink-muted">
                    This invitation was sent to
                    <span class="font-mono text-ink" data-testid="invite-email">
                      {@invited_email}
                    </span>
                    . Accepting joins you as a member.
                  </p>

                  <div class="mt-6 flex gap-3">
                    <.button phx-click="accept-invite" data-testid="invite-accept">
                      Accept invitation
                    </.button>
                    <.button
                      phx-click="decline-invite"
                      data-testid="invite-decline"
                      variant="secondary"
                    >
                      Decline
                    </.button>
                  </div>
                <% :email_mismatch -> %>
                  <h1 class="page-title mt-2">This invitation is for another address</h1>
                  <p class="mt-3 text-sm text-ink-muted" data-testid="invite-mismatch-copy">
                    It was sent to
                    <span class="font-mono text-ink" data-testid="invite-email">
                      {@invited_email}
                    </span>
                    . Sign in with that address to accept it.
                  </p>
                <% :accepted -> %>
                  <p class="mt-2 text-sm text-ink-muted" data-testid="invite-state-copy">
                    This invitation was already accepted.
                  </p>
                <% :revoked -> %>
                  <p class="mt-2 text-sm text-ink-muted" data-testid="invite-state-copy">
                    This invitation is no longer open.
                  </p>
                <% :expired -> %>
                  <p class="mt-2 text-sm text-ink-muted" data-testid="invite-state-copy">
                    This invitation expired. Ask the organization's owner to send a new one.
                  </p>
                <% :unknown_token -> %>
                  <p class="mt-2 text-sm text-ink-muted" data-testid="invite-state-copy">
                    This invitation link is not valid.
                  </p>
                <% :declined -> %>
                  <p class="mt-2 text-sm text-ink-muted" data-testid="invite-state-copy">
                    You declined the invitation to join {@invite.organization.name}.
                  </p>
              <% end %>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
