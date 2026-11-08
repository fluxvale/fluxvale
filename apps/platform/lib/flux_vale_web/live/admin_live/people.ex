defmodule FluxValeWeb.AdminLive.People do
  @moduledoc """
  The admin people surface (#501): the invitation list and the invite
  form. The list is every account with an invitation story (invite_state
  anything but :none), newest first, capped at the latest 100,
  with the stamps support acts on — invited at, expires at, accepted at,
  withdrawn at.

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

  `/admin` mounts this module's :home action and bounces to
  `/admin/people` (Am. 4 — the homepage cards retired, the first live
  section is the landing).
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxValeWeb.AdminShell

  require Ash.Query

  # The list cap (the moduledoc names it; move the two together): an
  # unbounded read is an ilike scan plus an unindexed sort waiting to
  # grow expensive, and the operator scans for what just happened
  # anyway. Revisit trigger: pagination and an invited_at index once
  # invitation volume approaches the cap.
  @list_cap 100

  @impl Phoenix.LiveView
  # `/admin` is no longer a surface of its own (Am. 4): the homepage
  # cards retired, the path bounces to the first live section. The
  # named :home action keeps this head apart from the surface's own
  # :index mount (the access panel's :personal posture, S5). Flash-free
  # — nothing failed.
  def mount(_params, _session, %{assigns: %{live_action: :home}} = socket) do
    {:ok, push_navigate(socket, to: ~p"/admin/people")}
  end

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
     |> assign(
       query: trimmed,
       search_form: to_form(%{"query" => trimmed}, as: :search),
       # The list moves under a reset, so an open confirm closes with it.
       withdrawing_id: nil,
       withdrawing_user: nil
     )
     |> refresh_rows()}
  end

  # The page's primary action: the one invite verb. The operation
  # resolves the occupant — an unoccupied address creates the inert
  # account, an invited one re-issues, a live account refuses. The copy
  # branch names the re-issue: an outstanding invitation means this
  # submit replaced a credential.
  # coveralls-ignore-start - OTP 28 cover never attributes a count to
  # this clause head; the clause demonstrably runs (the invite-form
  # tests drive it and the body's own lines all carry counts)
  def handle_event("invite", %{"invite" => %{"email" => email}}, socket) do
    # coveralls-ignore-stop
    address = String.trim(email)
    admin = socket.assigns.current_user

    # The copy branch is captured BEFORE the write: after it, the fresh
    # invite is itself an outstanding invitation and the question
    # answers itself.
    reissue? = outstanding_invitation?(admin, address)

    case Identity.invite_user(admin, address) do
      {:ok, _user, _raw} ->
        {:noreply,
         socket
         |> put_flash(:info, invite_sent_copy(reissue?))
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

      # The residual error class, NOT a mid-session demotion: the admin
      # check reads the mount-resolved struct (AdminGate is per-mount),
      # so what lands here is the occupant race between the operation's
      # read and its write, or the DB-down class. Neither is simulatable
      # under the sandbox.
      # coveralls-ignore-start
      {:error, _refused} ->
        refused =
          put_flash(
            socket,
            :error,
            gettext("The invite was refused. Sign out and sign back in, then try again.")
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
             "Reinvite sent. One email is on its way with a fresh one-time accept link. Any earlier link no longer works. If the email does not arrive, send another."
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

      # coveralls-ignore-start - the residual error class, not a
      # mid-session demotion (the admin check reads the mount-resolved
      # struct): the same occupant race or DB-down class as the invite
      # form above. Not simulatable under the sandbox.
      {:error, _refused} ->
        refused =
          put_flash(
            socket,
            :error,
            gettext("The reinvite was refused. Sign out and sign back in, then try again.")
          )

        {:noreply, refused}

        # coveralls-ignore-stop
    end
  end

  # Reveal the inline confirm under one row — after a fresh read
  # through the domain, so the reveal itself is a server-side state
  # check and a raced acceptance (or a crafted frame naming an accepted
  # account) never opens a confirm the domain would refuse anyway.
  #
  # The stream RESET re-renders every row from the new assigns, so any
  # confirm already open on another row collapses — a lone
  # stream_insert here let two panels coexist and the first row's
  # button act on the second record (the stale-panel defect class,
  # repaired in the moderation surface's review, pinned here).
  def handle_event("open-withdraw", %{"id" => id}, socket) do
    admin = socket.assigns.current_user

    with {:ok, user} <- Ash.get(User, id, actor: admin, load: [:invite_state]),
         :pending <- user.invite_state do
      revealed =
        socket
        |> assign(withdrawing_id: user.id, withdrawing_user: user)
        |> refresh_rows()

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

  # The destructive click on the inline confirm. Refusals are one
  # honest line: a raced acceptance (StaleRecord — the row's filter no
  # longer matches) and the DB-error class read the same from here, and
  # the refresh makes the row tell the truth either way.
  @impl Phoenix.LiveView
  def handle_event("confirm-withdraw", _params, socket) do
    admin = socket.assigns.current_user

    case Identity.withdraw_invite(admin, socket.assigns.withdrawing_user) do
      {:ok, _withdrawn} ->
        {:noreply, withdraw_done(socket, :info)}

      {:error, _changed_or_denied} ->
        {:noreply, withdraw_done(socket, :error)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("cancel-confirm", _params, socket) do
    # The reset re-renders every row, so the open panel actually leaves
    # the DOM (the stale-panel rule).
    {:noreply,
     socket
     |> assign(withdrawing_id: nil, withdrawing_user: nil)
     |> refresh_rows()}
  end

  defp withdraw_done(socket, :info) do
    socket
    |> put_flash(
      :info,
      gettext(
        "Invite withdrawn. Their accept link no longer works. The account stays inert until someone invites them again."
      )
    )
    |> assign(withdrawing_id: nil, withdrawing_user: nil)
    |> refresh_rows()
  end

  defp withdraw_done(socket, :error) do
    socket
    |> put_flash(
      :error,
      gettext("That invitation changed before the withdraw landed. The list is refreshed.")
    )
    |> assign(withdrawing_id: nil, withdrawing_user: nil)
    |> refresh_rows()
  end

  # -- reads ----------------------------------------------------------------

  # The copy branch ahead of the write: does this address already carry
  # an outstanding invitation (pending, withdrawn, expired)? Admins may
  # read users (the platform-admin policy), and the frozen email mirror
  # is the same address surface the operation's occupant resolution
  # resolves through. An accepted account never matches (its acceptance
  # stamp is set) and refuses at the domain as before.
  defp outstanding_invitation?(admin, address) do
    User
    |> Ash.Query.for_read(:read, %{}, actor: admin)
    |> Ash.Query.filter(
      email == ^address and not is_nil(invited_at) and is_nil(invite_accepted_at)
    )
    |> Ash.exists?(actor: admin)
  end

  # Delivery is best-effort after the committed write (the operation
  # logs and moves on), so the copy never promises the inbox: it names
  # the resend lever instead. The form is the one invite verb, so a
  # re-issue rides it silently at the domain; the branch says so. The
  # branch is decided before the write (see the call site).
  defp invite_sent_copy(reissue?) do
    if reissue? do
      gettext(
        "Reinvite sent. One email is on its way with a fresh one-time accept link. Any earlier link no longer works. The account stays inert until they accept. If the email does not arrive, use Reinvite to send another."
      )
    else
      gettext(
        "Invite sent. One email is on its way with a one-time accept link. The account stays inert until they accept. If the email does not arrive, use Reinvite to send another."
      )
    end
  end

  # One scope filter, the support ruling drawn in data: an invitation
  # story means invited_at is stamped (invite_state answers :none
  # exactly when it is nil). Newest first, capped (see @list_cap).
  defp refresh_rows(socket) do
    admin = socket.assigns.current_user

    # One past the cap answers the capped? question without a count.
    fetched =
      User
      |> Ash.Query.for_read(:read, %{}, actor: admin)
      |> Ash.Query.filter(not is_nil(invited_at))
      |> Ash.Query.sort(invited_at: :desc)
      |> maybe_search(socket.assigns.query)
      |> Ash.Query.limit(@list_cap + 1)
      |> Ash.Query.load(:invite_state)
      |> Ash.read!()

    capped? = length(fetched) > @list_cap
    users = Enum.take(fetched, @list_cap)

    socket
    |> assign(rows_empty?: users == [], rows_capped?: capped?)
    |> stream(:people, users, reset: true)
  end

  defp maybe_search(query, ""), do: query

  defp maybe_search(query, term) do
    Ash.Query.filter(query, ilike(email, ^"%#{term}%"))
  end

  # -- display helpers ------------------------------------------------------

  # Four distinct treatments: pending is the live credential (primary,
  # pulsing dot), accepted is done (success, check), expired timed out
  # (warning, clock), withdrawn rests (neutral, no cue). The cue is the
  # non-color half (status_badge's dot grammar) so no two states ever
  # share both tone and shape in either theme.
  defp state_tone(:pending), do: "primary"
  defp state_tone(:accepted), do: "success"
  defp state_tone(:expired), do: "warning"
  defp state_tone(_none_or_withdrawn), do: "neutral"

  defp state_cue(:pending), do: {:dot, :pulse}
  defp state_cue(:accepted), do: {:icon, "hero-check-circle"}
  defp state_cue(:expired), do: {:icon, "hero-clock"}
  defp state_cue(_none_or_withdrawn), do: nil

  defp state_label(:pending), do: gettext("Pending")
  defp state_label(:accepted), do: gettext("Accepted")
  defp state_label(:expired), do: gettext("Expired")
  defp state_label(:withdrawn), do: gettext("Withdrawn")

  # coveralls-ignore-start - the :none arm is the scope-widening guard:
  # the list filter keeps :none rows out today, so it cannot run
  defp state_label(:none), do: gettext("No invitation")
  # coveralls-ignore-stop

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

        <%!-- The section sidebar (Am. 4, the #568 idiom) owns
        cross-section wayfinding — no console-level back link. --%>
        <section class="wrap pt-8 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <AdminShell.sidebar current="people" />

            <div class="min-w-0 flex-1 space-y-6">
              <div class="grid items-start gap-6 lg:grid-cols-2">
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
                    <.button
                      type="submit"
                      phx-disable-with={gettext("Sending...")}
                      data-testid="admin-people-invite-submit"
                    >
                      {gettext("Send invite")}
                    </.button>
                  </.form>
                </.card>

                <.card class="space-y-4" data-testid="admin-people-search-card">
                  <div>
                    <h2 class="text-base font-medium text-ink">{gettext("Find an invitation")}</h2>
                    <p class="mt-1 text-sm text-ink-muted">
                      {gettext(
                        "Search narrows this list by invitation address. It never reaches past it."
                      )}
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
                      placeholder={gettext("Search by invitation address")}
                      phx-debounce="200"
                      data-testid="admin-people-search-input"
                    />
                  </.form>
                </.card>
              </div>

              <div class="space-y-4" data-testid="admin-people-list">
                <%!-- The count is the @list_cap above (kept literal here —
            a module attribute reads as assigns inside HEEx); move the
            two together. --%>
                <p
                  :if={@rows_capped?}
                  class="text-sm text-ink-muted"
                  data-testid="admin-people-capped"
                >
                  {gettext("Showing the latest 100 invitations.")}
                </p>

                <.empty_state
                  :if={@rows_empty? and @query == ""}
                  title={gettext("No invitations yet.")}
                >
                  {gettext(
                    "Invites you send, and the accounts they made, show up here. Accounts without an invitation story are not this page's business."
                  )}
                </.empty_state>

                <.empty_state
                  :if={@rows_empty? and @query != ""}
                  title={gettext("No invitation matches that email.")}
                />

                <div
                  :if={not @rows_empty?}
                  class="overflow-x-auto rounded-panel border border-line bg-panel text-ink"
                >
                  <div class="min-w-[39rem]">
                    <%!-- One grid template shared by the header and every
                row (kept literal in both spots), so the columns can
                never drift. Track mins total 37.5rem, so the populated list
                fits the band beside the sidebar at 1024+ with no horizontal
                scroll. --%>
                    <div class="grid grid-cols-[minmax(7.5rem,1.8fr)_5.5rem_repeat(4,4.25rem)_5.25rem] items-center gap-x-1.5 border-b border-line px-3 py-3 text-left text-xs font-medium tracking-wide text-ink-muted uppercase">
                      <div>{gettext("Email")}</div>
                      <div>{gettext("State")}</div>
                      <div>{gettext("Invited")}</div>
                      <div>{gettext("Expires")}</div>
                      <div>{gettext("Accepted")}</div>
                      <div>{gettext("Withdrawn")}</div>
                      <div class="sr-only">{gettext("Actions")}</div>
                    </div>

                    <div id="admin-people-table" phx-update="stream">
                      <div
                        :for={{dom_id, user} <- @streams.people}
                        id={dom_id}
                        class="border-b border-line last:border-0"
                      >
                        <div class="grid grid-cols-[minmax(7.5rem,1.8fr)_5.5rem_repeat(4,4.25rem)_5.25rem] items-center gap-x-1.5 px-3 py-3 transition-colors hover:bg-panel-raised/60">
                          <div class="min-w-0">
                            <span
                              class="block truncate whitespace-nowrap font-medium text-ink"
                              data-testid={"admin-people-email-#{user.id}"}
                              title={user.email}
                            >
                              {user.email}
                            </span>
                          </div>
                          <div>
                            <span data-testid={"admin-people-state-#{user.id}"}>
                              <.badge
                                tone={state_tone(user.invite_state)}
                                class="px-1.5! text-[11px]!"
                              >
                                <%= case state_cue(user.invite_state) do %>
                                  <% {:dot, :pulse} -> %>
                                    <span class="size-1.5 rounded-full bg-current motion-safe:animate-pulse" />
                                  <% {:icon, name} -> %>
                                    <.icon name={name} class="size-3.5" />
                                  <% nil -> %>
                                    <%!-- the resting states carry no cue --%>
                                <% end %>
                                {state_label(user.invite_state)}
                              </.badge>
                            </span>
                          </div>
                          <div>
                            <span
                              class="whitespace-nowrap text-xs text-ink-muted"
                              data-testid={"admin-people-invited-#{user.id}"}
                            >
                              {stamp_text(user.invited_at)}
                            </span>
                          </div>
                          <%!-- expiry is only meaningful while the link can
                      still be used; closed rows leave the cell empty --%>
                          <div>
                            <span
                              :if={user.invite_state == :pending}
                              class="whitespace-nowrap text-xs text-ink-muted"
                              data-testid={"admin-people-expires-#{user.id}"}
                            >
                              {stamp_text(user.invite_expires_at)}
                            </span>
                          </div>
                          <div>
                            <span
                              class="whitespace-nowrap text-xs text-ink-muted"
                              data-testid={"admin-people-accepted-#{user.id}"}
                            >
                              {stamp_text(user.invite_accepted_at)}
                            </span>
                          </div>
                          <div>
                            <span
                              class="whitespace-nowrap text-xs text-ink-muted"
                              data-testid={"admin-people-withdrawn-#{user.id}"}
                            >
                              {stamp_text(user.invite_withdrawn_at)}
                            </span>
                          </div>
                          <div>
                            <div class="flex items-center justify-end gap-2">
                              <button
                                :if={reinvite?(user.invite_state)}
                                type="button"
                                phx-click="reinvite"
                                phx-value-email={user.email}
                                phx-disable-with={gettext("Sending...")}
                                class="text-sm font-medium text-link underline-offset-2 hover:underline disabled:pointer-events-none disabled:opacity-50"
                                data-testid={"admin-people-reinvite-#{user.id}"}
                              >
                                {gettext("Reinvite")}
                              </button>
                              <.button
                                :if={withdrawable?(user.invite_state)}
                                size="sm"
                                variant="secondary"
                                phx-click="open-withdraw"
                                phx-value-id={user.id}
                                phx-disable-with={gettext("Opening...")}
                                data-testid={"admin-people-withdraw-#{user.id}"}
                              >
                                {gettext("Withdraw")}
                              </.button>
                            </div>
                          </div>
                        </div>

                        <%!-- The confirm expands directly under the row that
                    opened it (the backups page's posture): the action
                    and its consequence share one visual block. One
                    confirm per page — @withdrawing_id is the expansion
                    key, so the shared destructive-confirm testid stays
                    safe. The reveal rode a fresh domain read
                    (open-withdraw). --%>
                        <div :if={@withdrawing_id == user.id} class="px-4 pb-4">
                          <.confirm_block
                            title={
                              gettext("Withdraw the invite for %{email}?",
                                email: @withdrawing_user.email
                              )
                            }
                            body={
                              gettext(
                                "Their accept link stops working. The account remains inert until someone invites them again."
                              )
                            }
                            action={gettext("Yes, withdraw this invite")}
                            event="confirm-withdraw"
                            action_testid="admin-people-withdraw-confirm"
                            cancel_testid="admin-people-withdraw-cancel"
                            myself={nil}
                          />
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
