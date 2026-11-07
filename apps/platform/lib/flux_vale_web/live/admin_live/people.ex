defmodule FluxValeWeb.AdminLive.People do
  @moduledoc """
  The admin people surface (#501): the invitation list and the invite
  form. The list is every account with an invitation story (invite_state
  anything but :none), newest first, with the stamps support acts on —
  invited at, expires at, accepted at, withdrawn at.

  Deliberately NOT a user directory (the owner ruling on this lane's
  scope): accounts without an invitation story are not this page's
  business, and the empty state says so honestly. Username and org
  membership browsing live elsewhere, if anywhere.

  Every read and write rides the identity domain with the
  platform-admin actor and authorization on: invites and reinvites go
  through `Identity.invite_user/4` (the one invite verb — the operation
  resolves the occupant and refuses live accounts), withdrawals through
  `Identity.withdraw_invite/3`. No `authorize?: false` anywhere on this
  surface.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxValeWeb.AdminLive.WithdrawInviteConfirm

  require Ash.Query

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    # The chrome assigns (current_user, username, nav_section) ride the
    # AdminChrome on_mount on the :admin live_session — this mount adds
    # only the page's own data.
    {:ok,
     socket
     |> assign(query: "")
     |> assign(withdrawing_id: nil)
     |> assign(withdrawing_user: nil)
     |> assign(invite_form: to_form(%{"email" => ""}, as: :invite))
     |> assign(search_form: to_form(%{"query" => ""}, as: :search))
     |> refresh_rows()}
  end

  # -- events -------------------------------------------------------------

  @impl Phoenix.LiveView
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    trimmed = String.trim(query)

    {:noreply,
     socket
     |> assign(query: trimmed, search_form: to_form(%{"query" => trimmed}, as: :search))
     |> refresh_rows()}
  end

  # The page's primary action: the one invite verb. The operation
  # resolves the occupant — an unoccupied address creates the inert
  # account, an invited one re-issues, a live account refuses.
  # coveralls-ignore-start - OTP 28 cover never attributes a count to
  # this clause head; the clause demonstrably runs (the invite-form
  # tests drive it and the body's own lines all carry counts)
  def handle_event("invite", %{"invite" => %{"email" => email}}, socket) do
    # coveralls-ignore-stop
    address = String.trim(email)
    admin = socket.assigns.current_user

    case Identity.invite_user(admin, address) do
      {:ok, _user, _raw} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext(
             "Invite sent. A one-time accept link is in their inbox. The account stays inert until they accept."
           )
         )
         |> assign(invite_form: to_form(%{"email" => ""}, as: :invite))
         |> refresh_rows()}

      {:error, :invalid_address} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("That does not look like an email address. Nothing was sent.")
         )
         |> assign(invite_form: to_form(%{"email" => address}, as: :invite))}

      {:error, :already_active} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("That address already has an active account. Nothing was sent.")
         )
         |> assign(invite_form: to_form(%{"email" => address}, as: :invite))}

      # The socket's actor is fixed at mount and the admin check reads
      # the struct, so a mid-session demotion lands here — a state the
      # route gate owns (its 403 arm is pinned at the plug level) and
      # ExUnit cannot produce under a live socket.
      # coveralls-ignore-start
      {:error, _refused} ->
        refused =
          put_flash(
            socket,
            :error,
            gettext("The invite was refused. Your admin access may have changed.")
          )

        {:noreply, refused}

        # coveralls-ignore-stop
    end
  end

  # The resend lever's click. The domain is the gate: a raced acceptance
  # answers :already_active here, the same shape the invite form reads.
  def handle_event("reinvite", %{"email" => email}, socket) do
    admin = socket.assigns.current_user

    case Identity.invite_user(admin, email) do
      {:ok, _user, _raw} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext(
             "Reinvite sent. A fresh one-time accept link went out. Any earlier link no longer works."
           )
         )
         |> refresh_rows()}

      {:error, :invalid_address} ->
        refused = put_flash(socket, :error, gettext("That does not look like an email address."))

        {:noreply, refused}

      {:error, :already_active} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That account is already active. No link was sent."))
         |> refresh_rows()}

      # coveralls-ignore-start - same fixed-actor arm as the invite form
      # above: the route gate owns it, ExUnit cannot produce it here
      {:error, _refused} ->
        refused =
          put_flash(
            socket,
            :error,
            gettext("The reinvite was refused. Your admin access may have changed.")
          )

        {:noreply, refused}

        # coveralls-ignore-stop
    end
  end

  # Reveal the confirm panel for one row — after a fresh read through
  # the domain, so the reveal itself is a server-side state check and a
  # raced acceptance (or a crafted frame naming an accepted account)
  # never opens a confirm the domain would refuse anyway.
  def handle_event("open-withdraw", %{"id" => id}, socket) do
    admin = socket.assigns.current_user

    with {:ok, user} <- Ash.get(User, id, actor: admin, load: [:invite_state]),
         :pending <- user.invite_state do
      revealed = assign(socket, withdrawing_id: user.id, withdrawing_user: user)

      {:noreply, revealed}
    else
      # Anything but a pending invitation: the row moved (accepted,
      # withdrawn, expired) between the list render and the click. The
      # same flash covers the read-error arm (invited rows are never
      # deleted, so vanishing mid-session is the DB-down class — the
      # refreshed list is the honest answer there too).
      _changed ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That invitation changed. The list is refreshed."))
         |> refresh_rows()}
    end
  end

  # -- messages from the confirm component --------------------------------

  @impl Phoenix.LiveView
  def handle_info({:invite_withdrawn, _user_id}, socket) do
    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext(
         "Invite withdrawn. Their accept link no longer works. The account stays inert until someone invites them again."
       )
     )
     |> assign(withdrawing_id: nil, withdrawing_user: nil)
     |> refresh_rows()}
  end

  def handle_info({:invite_withdraw_failed, _user_id}, socket) do
    {:noreply,
     socket
     |> put_flash(
       :error,
       gettext("That invitation changed before the withdraw landed. The list is refreshed.")
     )
     |> assign(withdrawing_id: nil, withdrawing_user: nil)
     |> refresh_rows()}
  end

  def handle_info({:cancel_withdraw}, socket) do
    {:noreply, assign(socket, withdrawing_id: nil, withdrawing_user: nil)}
  end

  # -- reads ----------------------------------------------------------------

  # One scope filter, the support ruling drawn in data: an invitation
  # story means invited_at is stamped (invite_state answers :none
  # exactly when it is nil). Newest first for the operator scanning for
  # what just happened.
  defp refresh_rows(socket) do
    admin = socket.assigns.current_user

    users =
      User
      |> Ash.Query.for_read(:read, %{}, actor: admin)
      |> Ash.Query.filter(not is_nil(invited_at))
      |> Ash.Query.sort(invited_at: :desc)
      |> maybe_search(socket.assigns.query)
      |> Ash.Query.load(:invite_state)
      |> Ash.read!()

    socket
    |> assign(rows_empty?: users == [])
    |> stream(:people, users, reset: true)
  end

  defp maybe_search(query, ""), do: query

  defp maybe_search(query, term) do
    Ash.Query.filter(query, ilike(email, ^"%#{term}%"))
  end

  # -- display helpers ------------------------------------------------------

  defp state_tone(:pending), do: "primary"
  defp state_tone(:accepted), do: "success"
  defp state_tone(_withdrawn_or_expired), do: "neutral"

  defp state_label(:pending), do: gettext("Pending")
  defp state_label(:accepted), do: gettext("Accepted")
  defp state_label(:withdrawn), do: gettext("Withdrawn")
  defp state_label(:expired), do: gettext("Expired")

  defp reinvite?(state), do: state in [:pending, :withdrawn, :expired]
  defp withdrawable?(state), do: state == :pending

  defp stamp_text(nil), do: nil
  defp stamp_text(stamp), do: Calendar.strftime(stamp, "%b %d, %Y")

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
      <div class="appgram contents" data-testid="admin-people">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5">{gettext("People and invites")}</h1>
              <p class="mt-2 max-w-prose text-base text-ink-muted">
                {gettext(
                  "Invitations and the accounts they made. A support surface, not a user directory. Accounts with no invitation story are not this page's business."
                )}
              </p>
            </div>
          </div>
        </section>

        <section class="wrap pt-8 pb-8">
          <div class="rise grid gap-6 lg:grid-cols-2">
            <%!-- The page's primary action. The consequence is named
            before the click: one email, one-time link, inert account. --%>
            <.card class="space-y-4" data-testid="admin-people-invite-card">
              <div>
                <h2 class="text-base font-medium text-ink">{gettext("Invite someone")}</h2>
                <p class="mt-1 text-sm text-ink-muted">
                  {gettext(
                    "One email goes out with a one-time accept link. The account stays inert until the link is used."
                  )}
                </p>
              </div>
              <.form
                for={@invite_form}
                id="admin-people-invite-form"
                phx-submit="invite"
                class="space-y-4"
              >
                <.input
                  field={@invite_form[:email]}
                  type="email"
                  label={gettext("Email")}
                  data-testid="admin-people-invite-email"
                />
                <.button type="submit" data-testid="admin-people-invite-submit">
                  {gettext("Send invite")}
                </.button>
              </.form>
            </.card>

            <.card class="space-y-4" data-testid="admin-people-search-card">
              <div>
                <h2 class="text-base font-medium text-ink">{gettext("Find an invitation")}</h2>
                <p class="mt-1 text-sm text-ink-muted">
                  {gettext("Search narrows this list by email. It never reaches past it.")}
                </p>
              </div>
              <.form
                for={@search_form}
                id="admin-people-search"
                phx-change="search"
                phx-submit="search"
              >
                <.input
                  field={@search_form[:query]}
                  type="text"
                  label={gettext("Email")}
                  placeholder={gettext("Search by email")}
                  phx-debounce="200"
                  data-testid="admin-people-search-input"
                />
              </.form>
            </.card>
          </div>
        </section>

        <section class="wrap pt-4 pb-16">
          <div class="rise space-y-4" data-testid="admin-people-list">
            <.empty_state :if={@rows_empty? and @query == ""} title={gettext("No invitations yet.")}>
              {gettext(
                "Invites you send, and the accounts they made, show up here. Accounts without an invitation story are not this page's business."
              )}
            </.empty_state>

            <.empty_state
              :if={@rows_empty? and @query != ""}
              title={gettext("No invitation matches that email.")}
            />

            <.table
              :if={not @rows_empty?}
              id="admin-people-table"
              rows={@streams.people}
              row_item={fn {_id, user} -> user end}
            >
              <:col :let={user} label={gettext("Email")}>
                <span class="font-medium text-ink" data-testid={"admin-people-email-#{user.id}"}>
                  {user.email}
                </span>
              </:col>
              <:col :let={user} label={gettext("State")}>
                <span data-testid={"admin-people-state-#{user.id}"}>
                  <.badge tone={state_tone(user.invite_state)}>
                    {state_label(user.invite_state)}
                  </.badge>
                </span>
              </:col>
              <:col :let={user} label={gettext("Invited")}>
                <span class="whitespace-nowrap" data-testid={"admin-people-invited-#{user.id}"}>
                  {stamp_text(user.invited_at)}
                </span>
              </:col>
              <:col :let={user} label={gettext("Expires")}>
                <span class="whitespace-nowrap" data-testid={"admin-people-expires-#{user.id}"}>
                  {stamp_text(user.invite_expires_at)}
                </span>
              </:col>
              <:col :let={user} label={gettext("Accepted")}>
                <span class="whitespace-nowrap" data-testid={"admin-people-accepted-#{user.id}"}>
                  {stamp_text(user.invite_accepted_at)}
                </span>
              </:col>
              <:col :let={user} label={gettext("Withdrawn")}>
                <span class="whitespace-nowrap" data-testid={"admin-people-withdrawn-#{user.id}"}>
                  {stamp_text(user.invite_withdrawn_at)}
                </span>
              </:col>
              <:action :let={user}>
                <div class="flex gap-4">
                  <.button
                    :if={reinvite?(user.invite_state)}
                    size="sm"
                    variant="ghost"
                    phx-click="reinvite"
                    phx-value-email={user.email}
                    data-testid={"admin-people-reinvite-#{user.id}"}
                  >
                    {gettext("Reinvite")}
                  </.button>
                  <.button
                    :if={withdrawable?(user.invite_state)}
                    size="sm"
                    variant="destructive"
                    phx-click="open-withdraw"
                    phx-value-id={user.id}
                    data-testid={"admin-people-withdraw-#{user.id}"}
                  >
                    {gettext("Withdraw")}
                  </.button>
                </div>
              </:action>
            </.table>

            <%!-- One confirm per page, mounted for the one row being
            withdrawn — the shared destructive-confirm testid stays
            safe. The reveal rides a fresh domain read (open-withdraw). --%>
            <.live_component
              :if={@withdrawing_user}
              module={WithdrawInviteConfirm}
              id="withdraw-invite-confirm"
              user={@withdrawing_user}
              actor={@current_user}
            />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
