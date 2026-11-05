defmodule FluxValeWeb.OrganizationLive.Members do
  @moduledoc """
  Org settings, Members tab (#276): the roster — email, role, joined —
  plus the member lifecycle (slice 5 of #408): owners set roles and
  remove members, a member leaves from their own row, and the last-owner
  guard's refusal renders as the plain flash sentence. The owner's
  invite surface (slice 4 of #408) sits below the roster: the invite
  form and the pending-invites list with revoke. Slug-keyed mount like
  Settings; unknown slugs (and policy denials) read as "not here" —
  never a bare 404.

  Membership create stays system-only (the invite flow joins through
  the token path), so the roster itself is not an admin console. The
  FORMS are UX on top of the actions' owner policies: those are the
  authority. The personal org has no members page at all (S5): exactly
  one member — the user — so its URL redirects to `/settings`.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.MembershipInvite
  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.Identity.UserEmail
  alias FluxValeWeb.OrgSettings
  alias FluxValeWeb.PersonalOrg

  require Ash.Query

  @impl Phoenix.LiveView
  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Organization.get_by_slug(slug, actor: user) do
      {:ok, org} ->
        if PersonalOrg.personal?(socket, org) do
          # S5: exactly one member (the user) — no members page for the
          # personal org; the account surfaces live at /settings.
          {:ok, push_navigate(socket, to: ~p"/settings")}
        else
          mount_roster(socket, org)
        end

      _error ->
        {:ok,
         socket
         |> put_flash(:error, "Organization not found.")
         |> push_navigate(to: ~p"/")}
    end
  end

  # The org read policy already answered this mount: its grant is the
  # org's members, so every actor here sees the roster (slice 5 opened
  # the tab to them — the Leave affordance). The owner check is no
  # longer a gate, it selects the affordances: role and removal
  # controls render for owners only, and the actions' policies stay the
  # authority for every write.
  defp mount_roster(socket, org) do
    {:ok,
     socket
     |> assign(:org, org)
     |> assign(:invite_form, invite_form())
     |> stream_configure(:members, dom_id: &"member-row-#{&1.id}")
     |> refresh_roster()
     |> stream_configure(:invites, dom_id: &"pending-invite-#{&1.id}")
     |> refresh_invites()}
  end

  @impl Phoenix.LiveView
  def handle_event("set-role", %{"id" => id, "role" => role_param}, socket) do
    user = socket.assigns.current_user

    case find_member(socket, id) do
      nil ->
        {:noreply, member_gone(socket)}

      membership ->
        # The control posts exactly "owner" or "member"; any other value
        # collapses to :member — the enum and the owner policy remain the
        # authority, and demote is the conservative direction of the two.
        role = parse_role(role_param)

        case Accounts.set_member_role(user, membership, role) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> put_flash(:info, "Role updated.")
             |> refresh_roster()}

          {:error, :last_owner} ->
            {:noreply,
             socket
             |> put_flash(:error, Accounts.guard_message(:set_member_role))
             |> refresh_roster()}

          # The owner policy is the authority; a refused write lands
          # here (a demoted former owner's stale page, say). The roster
          # refreshes so the page shows the row's truth.
          {:error, _refused} ->
            {:noreply,
             socket
             |> put_flash(:error, "Could not update the role.")
             |> refresh_roster()}
        end
    end
  end

  def handle_event("remove-member", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case find_member(socket, id) do
      nil ->
        {:noreply, member_gone(socket)}

      membership ->
        case Accounts.remove_member(user, membership) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Member removed.")
             |> refresh_roster()}

          {:error, :last_owner} ->
            {:noreply,
             socket
             |> put_flash(:error, Accounts.guard_message(:remove_member))
             |> refresh_roster()}

          {:error, _refused} ->
            {:noreply,
             socket
             |> put_flash(:error, "Could not remove the member.")
             |> refresh_roster()}
        end
    end
  end

  def handle_event("leave", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case find_member(socket, id) do
      nil ->
        {:noreply, member_gone(socket)}

      # A crafted frame naming ANOTHER member's row: the seam's
      # self-only policy refuses it (the page never renders Leave on a
      # foreign row).
      membership ->
        case Accounts.leave_organization(user, membership) do
          :ok ->
            # The actor lands on their own account surface: a
            # push_navigate INSIDE the :authenticated session (an
            # event-time push to the controller-routed "/" would kill
            # the page — a live navigation must target a live route).
            # The flash rides the navigation.
            {:noreply,
             socket
             |> put_flash(:info, "You left the organization.")
             |> push_navigate(to: ~p"/settings")}

          {:error, :last_owner} ->
            {:noreply,
             socket
             |> put_flash(:error, Accounts.guard_message(:leave_organization))
             |> refresh_roster()}

          {:error, _refused} ->
            {:noreply,
             socket
             |> put_flash(:error, "Could not leave the organization.")
             |> refresh_roster()}
        end
    end
  end

  def handle_event("invite", %{"invite" => %{"email" => typed}}, socket) do
    email = String.trim(typed)

    if UserEmail.valid_address?(email) do
      case Accounts.invite_member(socket.assigns.current_user, socket.assigns.org, email) do
        {:ok, _invite} ->
          {:noreply,
           socket
           |> put_flash(:info, "Invitation sent to #{email}.")
           |> assign(:invite_form, invite_form())
           |> refresh_invites()}

        {:error, :duplicate_invite} ->
          {:noreply,
           assign(socket,
             invite_form:
               invite_form(email: email, errors: [email: {"already has an open invitation", []}])
           )}

        # The seam carries the same format fence (the operation is what
        # every caller crosses — the RequestAuthCode posture); this arm
        # is that fence's page face. Unreachable from THIS page today —
        # the eager check above answers first — pinned by the operation
        # suite; the arm keeps the page honest if the pre-check and the
        # seam ever disagree.
        # coveralls-ignore-next-line
        {:error, :invalid_email} ->
          {:noreply,
           assign(socket,
             invite_form:
               invite_form(email: email, errors: [email: {"must be a valid email address", []}])
           )}

        {:error, _other} ->
          # The owner policy is the authority; a refused create lands
          # here (the org gone underneath the mounted page — pinned by
          # the gone-org submit test). The list refreshes so the page
          # shows the row's truth.
          {:noreply,
           socket
           |> put_flash(:error, "Could not send the invitation.")
           |> refresh_invites()}
      end
    else
      # The same rule, checked eagerly: the field error renders without
      # the round-trip (the settings form's validate posture).
      {:noreply,
       assign(socket,
         invite_form:
           invite_form(email: email, errors: [email: {"must be a valid email address", []}])
       )}
    end
  end

  def handle_event("revoke-invite", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    # The id is a client value: resolution happens in memory over the
    # policy-scoped list (the Access tab posture — a crafted id must
    # answer "no longer pending", never crash the lookup).
    invite = Enum.find(socket.assigns.invites, &(&1.id == id))

    socket =
      case invite do
        nil ->
          # Not in the mounted list: already gone (revoked, expired,
          # org teardown) or never real (a crafted id) — the refresh
          # below shows the page the truth.
          put_flash(socket, :error, "That invitation is no longer pending.")

        invite ->
          case Accounts.revoke_invite(user, invite) do
            {:ok, _revoked} ->
              put_flash(socket, :info, "Invitation revoked.")

            # The row moved between mount and click — accepted
            # elsewhere (the revoke action filters accepted rows, so
            # the write matches nothing). Same answer as the nil arm:
            # nothing here left to revoke.
            {:error, _refused} ->
              put_flash(socket, :error, "That invitation is no longer pending.")
          end
      end

    {:noreply, refresh_invites(socket)}
  end

  # The id is a client value: resolution happens in memory over the
  # policy-scoped roster (the revoke-invite posture — a crafted id
  # answers the plain refusal, never a crash).
  defp find_member(socket, id) do
    Enum.find(socket.assigns.members, &(&1.id == id))
  end

  defp member_gone(socket) do
    socket
    |> put_flash(:error, "That member is no longer on the roster.")
    |> refresh_roster()
  end

  # Every mutation re-derives the owner flag too: demoting yourself
  # (a second owner present) must fold the page back to the member view.
  defp refresh_roster(socket) do
    members = list_members(socket.assigns.org, socket.assigns.current_user)

    socket
    |> assign(
      :owner?,
      ActorIsOrganizationOwner.owner?(socket.assigns.current_user, socket.assigns.org)
    )
    |> assign(:members, members)
    |> stream(:members, members, reset: true)
  end

  defp refresh_invites(socket) do
    invites = list_invites(socket.assigns.org, socket.assigns.current_user)

    socket
    |> assign(:invites, invites)
    |> assign(:invites_empty?, invites == [])
    |> stream(:invites, invites, reset: true)
  end

  # The invite seam's duplicate arm is the friendly answer; this
  # pre-check spares the network round-trip and renders the field
  # error eagerly (the settings form's validate posture). Errors ride
  # the gettext tuple shape the input component translates.
  defp invite_form(opts \\ []) do
    params = %{"email" => Keyword.get(opts, :email, "")}
    to_form(params, as: "invite", errors: Keyword.get(opts, :errors, []))
  end

  defp parse_role("owner"), do: :owner
  defp parse_role(_other), do: :member

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
      current_org={@org}
      bare
    >
      <%!-- App-wide grammar page (S10): `bare` main + .appgram — the
      page owns ALL of main's rhythm. The roster rides the row/list
      language (the S4 row shell, no links — rows are not navigable), --%>
      <div class="appgram contents">
        <OrgSettings.org_header org={@org} surface="Members" />

        <section class="wrap pt-8 pb-16">
          <div class="rise space-y-6">
            <OrgSettings.settings_tabs current="members" slug={@org.slug} />

            <div>
              <h2 class="text-base font-medium text-ink">Members</h2>
              <p class="mt-1 text-sm text-ink-muted">People with access to this organization.</p>
            </div>

            <%!-- The container keeps the table's old id — the row-order
            assertion renders this element. Column semantics ride
            sr-only labels (the row language has no visible header
            row); emails are technical and ride the mono register. --%>
            <ul id="org-members-table" phx-update="stream" class="space-y-3">
              <li
                :for={{dom_id, member} <- @streams.members}
                id={dom_id}
                data-testid="member-row"
                class="rounded-panel border border-line-strong bg-panel p-4 shadow-sm sm:p-5"
              >
                <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-3">
                  <div class="min-w-0">
                    <p class="font-mono text-sm font-medium text-ink [overflow-wrap:anywhere]">
                      {member.user_email}
                    </p>
                    <p class="mt-0.5 whitespace-nowrap text-xs text-ink-subtle">
                      <span class="sr-only">Joined </span>{Calendar.strftime(
                        member.created_at,
                        "%b %d, %Y"
                      )}
                    </p>
                  </div>
                  <%!-- The badge is named for screen readers (hostile-355
                  F2): the row language has no table semantics, so the
                  role doesn't ride a column header — the sr-only prefix
                  is what makes the roster read as email, joined date,
                  "Role Owner". --%>
                  <div class="flex flex-wrap items-center gap-2">
                    <.badge tone="primary">
                      <span class="sr-only">Role </span>{role_label(member.role)}
                    </.badge>

                    <%!-- Owner affordances (slice 5 of #408): the role
                    control and Remove ride the set_role/remove_member
                    policies — the buttons are UX, the actions are the
                    authority. Leave lives on the actor's OWN row,
                    owners included. --%>
                    <%= if @owner? do %>
                      <%= if member.role == :owner do %>
                        <.button
                          phx-click="set-role"
                          phx-value-id={member.id}
                          phx-value-role="member"
                          data-testid={"demote-#{member.id}"}
                          variant="secondary"
                          size="sm"
                        >
                          Make member
                        </.button>
                      <% else %>
                        <.button
                          phx-click="set-role"
                          phx-value-id={member.id}
                          phx-value-role="owner"
                          data-testid={"promote-#{member.id}"}
                          variant="secondary"
                          size="sm"
                        >
                          Make owner
                        </.button>
                      <% end %>

                      <%= if member.user_id != @current_user.id do %>
                        <.button
                          phx-click="remove-member"
                          phx-value-id={member.id}
                          data-testid={"remove-member-#{member.id}"}
                          variant="secondary"
                          size="sm"
                        >
                          Remove
                        </.button>
                      <% end %>
                    <% end %>

                    <%= if member.user_id == @current_user.id do %>
                      <.button
                        phx-click="leave"
                        phx-value-id={member.id}
                        data-testid={"leave-#{member.id}"}
                        variant="secondary"
                        size="sm"
                      >
                        Leave
                      </.button>
                    <% end %>
                  </div>
                </div>
              </li>
            </ul>

            <div :if={@owner?}>
              <h2 class="text-base font-medium text-ink">Invitations</h2>
              <p class="mt-1 text-sm text-ink-muted">
                Invite someone by email. They accept from the link after signing in with that
                address.
              </p>
            </div>

            <.form
              :if={@owner?}
              for={@invite_form}
              id="invite-form"
              phx-submit="invite"
              data-testid="members-invite-form"
              class="rounded-panel border border-line-strong bg-panel p-4 shadow-sm sm:p-5"
            >
              <div class="flex flex-wrap items-start gap-3">
                <div class="min-w-0 flex-1">
                  <.input
                    field={@invite_form[:email]}
                    type="email"
                    label="Email address"
                    placeholder="name@example.com"
                    required
                  />
                </div>
                <.button
                  type="submit"
                  data-testid="invite-submit"
                  class="mt-0 sm:mt-6"
                >
                  Send invite
                </.button>
              </div>
            </.form>

            <div :if={@owner?} data-testid="pending-invites">
              <ul id="pending-invites" phx-update="stream">
                <li
                  :for={{dom_id, invite} <- @streams.invites}
                  id={dom_id}
                  data-testid="pending-invite-row"
                  class="rounded-panel border border-line-strong bg-panel p-4 shadow-sm sm:p-5"
                >
                  <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
                    <div class="min-w-0">
                      <p class="font-mono text-sm font-medium text-ink [overflow-wrap:anywhere]">
                        {invite.email}
                      </p>
                      <p class="mt-0.5 whitespace-nowrap text-xs text-ink-subtle">
                        <span class="sr-only">Invited </span>{Calendar.strftime(
                          invite.created_at,
                          "%b %d, %Y"
                        )}
                      </p>
                    </div>
                    <.button
                      phx-click="revoke-invite"
                      phx-value-id={invite.id}
                      data-testid={"revoke-invite-#{invite.id}"}
                      variant="secondary"
                      size="sm"
                    >
                      Revoke
                    </.button>
                  </div>
                </li>
              </ul>

              <%!-- Streams carry no empty state — the quiet shape rides
              the tracked assign (the LiveView streams posture). --%>
              <p
                :if={@invites_empty?}
                data-testid="pending-invites-empty"
                class="py-2 text-sm text-ink-subtle"
              >
                No pending invitations.
              </p>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # The organization_id filter is load-bearing, not redundant: the read
  # policy scopes rows to the actor's own orgs — plural — and this is
  # what narrows them to the org on the URL (pinned by the two-org test).
  # Owners first, then joined-asc; id is the tiebreak (uuid_v7 is
  # time-ordered, so equal timestamps still sort deterministically).
  # The date key is iso8601 — DateTime structs don't term-compare
  # chronologically, so the default `<=` would sort day-of-month first.
  defp list_members(org, user) do
    memberships =
      Membership
      |> Ash.Query.for_read(:read, %{}, actor: user)
      |> Ash.Query.filter(organization_id == ^org.id)
      |> Ash.Query.load([:user_email])
      |> Ash.read!()

    Enum.sort_by(memberships, &{&1.role != :owner, DateTime.to_iso8601(&1.created_at), &1.id})
  end

  # The OPEN invites of this org only — accepted and revoked rows are
  # history, and an expired row is not pending either (re-inviting
  # supersedes it; the seam owns that), so the queue shows exactly the
  # rows a revoke can act on. Invited-asc, then id (the list_members
  # tiebreak posture). Policy-scoped: the read action's org-members
  # grant carries it; the organization_id filter pins the tenant.
  defp list_invites(org, user) do
    MembershipInvite
    |> Ash.Query.for_read(:read, %{}, actor: user)
    |> Ash.Query.filter(
      organization_id == ^org.id and
        is_nil(accepted_at) and is_nil(revoked_at) and expires_at > now()
    )
    |> Ash.Query.sort(created_at: :asc, id: :asc)
    |> Ash.read!()
  end

  defp role_label(:owner), do: "Owner"
  defp role_label(:member), do: "Member"
end
