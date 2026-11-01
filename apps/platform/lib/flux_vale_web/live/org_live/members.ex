defmodule FluxValeWeb.OrganizationLive.Members do
  @moduledoc """
  Org settings, Members tab (#276): the read-only roster — email, role,
  joined. Slug-keyed mount like Settings; unknown slugs (and policy
  denials) read as "not here" — never a bare 404.

  Membership create/destroy are system-only until team features arrive,
  so the tab is a roster, not an admin console — the copy under the
  table says so instead of promising a timeline. The personal org has
  no members page at all (S5): exactly one member — the user — so its
  URL redirects to `/settings`.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorIsOrganizationOwner
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
       |> stream_configure(:members, dom_id: &"member-row-#{&1.id}")
       |> stream(:members, list_members(org, user))}
    else
      {:ok,
       socket
       |> put_flash(:error, "Only organization owners can access settings.")
       |> push_navigate(to: ~p"/")}
    end
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

            <p class="text-xs text-ink-subtle" data-testid="members-invite-note">
              Invitations arrive with team features.
            </p>
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

  defp role_label(:owner), do: "Owner"
  defp role_label(:member), do: "Member"
end
