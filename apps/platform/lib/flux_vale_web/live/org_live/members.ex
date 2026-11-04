defmodule FluxValeWeb.OrganizationLive.Members do
  @moduledoc """
  Org settings, Members tab (#276): the read-only roster — email, role,
  joined — plus the owner's invite surface (slice 4 of #408): the
  invite form and the pending-invites list with revoke. Slug-keyed
  mount like Settings; unknown slugs (and policy denials) read as
  "not here" — never a bare 404.

  Membership create/destroy stay system-only (the invite flow joins
  through the token path, slice 5 adds removal), so the roster itself
  is not an admin console. The invite FORM is UX on top of the
  actions' owner policies: those are the authority. The personal org
  has no members page at all (S5): exactly one member — the user — so
  its URL redirects to `/settings`.
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
          mount_roster(socket, org, user)
        end

      _error ->
        {:ok,
         socket
         |> put_flash(:error, "Organization not found.")
         |> push_navigate(to: ~p"/")}
    end
  end

  defp mount_roster(socket, org, user) do
    # UX gate, not the authority: the read policy scopes roster rows to
    # the actor's own orgs, and the query's organization_id filter is
    # what narrows them to THIS org — both are load-bearing (pinned by
    # the two-org test). The gate itself only spares a member a
    # settings surface that is owners-only — same posture as Settings.
    if ActorIsOrganizationOwner.owner?(user, org) do
      {:ok,
       socket
       |> assign(:org, org)
       |> assign(:invite_form, invite_form())
       |> stream_configure(:members, dom_id: &"member-row-#{&1.id}")
       |> stream(:members, list_members(org, user))
       |> stream_configure(:invites, dom_id: &"pending-invite-#{&1.id}")
       |> refresh_invites()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Only organization owners can access settings.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl Phoenix.LiveView
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
          # Already gone (revoked elsewhere, expired, org teardown) —
          # the refresh below shows the page the truth.
          put_flash(socket, :error, "That invitation is no longer pending.")

        invite ->
          case Accounts.revoke_invite(user, invite) do
            {:ok, _revoked} -> put_flash(socket, :info, "Invitation revoked.")
            # Defensive: a found-then-refused write has no trigger
            # today — the open-filtered list above answers every state
            # the row can move to, and a mounted owner's revoke passes
            # the owner policy. Revisit with slice 5's removal flow,
            # when an owner can lose the grant mid-session.
            # coveralls-ignore-next-line
            {:error, _refused} -> put_flash(socket, :error, "Could not revoke the invitation.")
          end
      end

    {:noreply, refresh_invites(socket)}
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
                <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
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
                  <.badge tone="primary">
                    <span class="sr-only">Role </span>{role_label(member.role)}
                  </.badge>
                </div>
              </li>
            </ul>

            <div class="pt-2">
              <h2 class="text-base font-medium text-ink">Invitations</h2>
              <p class="mt-1 text-sm text-ink-muted">
                Invite someone by email. They accept from the link after signing in with that
                address.
              </p>
            </div>

            <.form
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

            <div data-testid="pending-invites">
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
