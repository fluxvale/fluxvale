defmodule FluxValeWeb.OrganizationLive.Members do
  @moduledoc """
  Org settings, Members tab (#276): the read-only roster — email, role,
  joined. Slug-keyed mount like Settings; unknown slugs (and policy
  denials) read as "not here" — never a bare 404.

  Membership create/destroy are system-only until team features arrive,
  so the tab is a roster, not an admin console — the copy under the
  table says so instead of promising a timeline.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxValeWeb.OrgSettings

  require Ash.Query

  @impl Phoenix.LiveView
  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Organization.get_by_slug(slug, actor: user) do
      {:ok, org} ->
        # UX gate, not the authority: the read policy already scopes the
        # roster rows to the actor's own org. This just spares a member
        # a settings surface that is owners-only — same posture as
        # Settings.
        if ActorIsOrganizationOwner.owner?(user, org) do
          {:ok, assign(socket, org: org, members: list_members(org, user))}
        else
          {:ok,
           socket
           |> put_flash(:error, "Only organization owners can access settings.")
           |> push_navigate(to: ~p"/")}
        end

      _error ->
        {:ok,
         socket
         |> put_flash(:error, "Organization not found.")
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
      current_org={@org}
    >
      <div class="mx-auto max-w-3xl space-y-6">
        <OrgSettings.settings_tabs current="members" slug={@org.slug} />

        <div>
          <h2 class="text-base font-medium text-ink">Members</h2>
          <p class="mt-1 text-sm text-ink-muted">People with access to this organization.</p>
        </div>

        <.table id="org-members-table" rows={@members} row_id={&"member-row-#{&1.id}"}>
          <:col :let={member} label="Email">{member.user_email}</:col>
          <:col :let={member} label="Role">
            <span class="inline-flex items-center rounded-full bg-primary-muted px-2 py-0.5 text-xs font-medium text-primary">
              {role_label(member.role)}
            </span>
          </:col>
          <:col :let={member} label="Joined">
            <span class="whitespace-nowrap text-ink-muted">
              {Calendar.strftime(member.created_at, "%b %d, %Y")}
            </span>
          </:col>
        </.table>

        <p class="text-xs text-ink-subtle" data-testid="members-invite-note">
          Invitations arrive with team features.
        </p>
      </div>
    </Layouts.app>
    """
  end

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
