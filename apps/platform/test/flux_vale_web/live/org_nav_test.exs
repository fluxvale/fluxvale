defmodule FluxValeWeb.OrgNavTest do
  @moduledoc """
  The chrome's org-data hook (#276): assigns the actor's memberships
  (org loaded) plus the switcher's personal-row facts — the owned org's
  id and the handle that labels it (#285 T6) — and never halts, the
  empty and anonymous cases included.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxValeWeb.OrgNav

  require Ash.Query

  test "assigns the actor's orgs, the personal org id, and the handle" do
    user = AccountsFixtures.user!()
    org = AccountsFixtures.personal_org!(user)

    assert {:cont, socket} = OrgNav.on_mount(:assign_orgs, %{}, %{}, socket_with(user))
    assert [%{role: :owner, organization: %{id: org_id}}] = socket.assigns.actor_orgs
    assert org_id == org.id
    # personal_org_id is the canonical resolver's answer — the same op
    # the dashboard wallet and billing mount read.
    assert socket.assigns.personal_org_id == org.id
    assert socket.assigns.username == user.username
  end

  test "two memberships: personal_org_id is the owned org, personal row first" do
    user = AccountsFixtures.user!()
    personal = AccountsFixtures.personal_org!(user)
    team = team_org!(user)

    assert {:cont, socket} = OrgNav.on_mount(:assign_orgs, %{}, %{}, socket_with(user))

    assert socket.assigns.personal_org_id == personal.id

    # Both memberships are :owner today (the default role) — the
    # canonical op's pick (the org row it resolves first) is the
    # personal org, and the row order is pinned personal-first (#276),
    # the rest in creation order — the raw DB list carries no order to
    # pin. The canonical tie-break for two-owned-orgs users is a T7
    # question; this pins only that the switcher follows the resolver.
    assert [
             %{organization: %{id: first}},
             %{organization: %{id: second}}
           ] = socket.assigns.actor_orgs

    assert first == personal.id
    assert second == team.id
  end

  # ordered_orgs/2's teeth (#285 T6 review): the raw read carries no
  # order the pin could ride, so the seed forces one that disagrees
  # with creation order — memberships with explicit ids out of
  # chronological sequence (Ash.Seed — the documented exception: the
  # create action generates ids, so this is a state actions can't
  # produce). Pinned output: personal first, then id (creation) order,
  # whatever order the raw list comes back in. Mutation-checked: an
  # identity `ordered_orgs` fails this test.
  test "row order: personal first, then creation order — raw list order notwithstanding" do
    user = AccountsFixtures.user!()
    personal = AccountsFixtures.personal_org!(user)

    # uuid_v7 ids sort chronologically; two fresh generates, sorted,
    # give an (earlier, later) id pair without clock games.
    generated = [Ash.UUID.generate(), Ash.UUID.generate()]
    [early_id, late_id] = Enum.sort(generated)

    first_created =
      Organization.create!(
        %{name: "Team Org", slug: "order-first-#{System.unique_integer([:positive])}"},
        authorize?: false
      )

    second_created =
      Organization.create!(
        %{name: "Team Org", slug: "order-second-#{System.unique_integer([:positive])}"},
        authorize?: false
      )

    # Seeded in the opposite order of their ids — the row with the
    # LATER id lands first, so insertion (heap) order and id order
    # disagree.
    Ash.Seed.seed!(Membership, %{id: late_id, organization_id: first_created.id, user_id: user.id})

    Ash.Seed.seed!(Membership, %{
      id: early_id,
      organization_id: second_created.id,
      user_id: user.id
    })

    # Precondition: the seeded shape must actually diverge, else this
    # test proves nothing — the raw read (system posture, no actor)
    # comes back out of id order.
    {:ok, raw} = Accounts.organizations_for_user(user.id, authorize?: false)
    raw_ids = Enum.map(raw, & &1.id)
    assert raw_ids != Enum.sort(raw_ids)

    assert {:cont, socket} = OrgNav.on_mount(:assign_orgs, %{}, %{}, socket_with(user))

    personal_id = personal.id
    second_id = second_created.id
    first_id = first_created.id

    assert [
             %{organization: %{id: ^personal_id}},
             %{organization: %{id: ^second_id}},
             %{organization: %{id: ^first_id}}
           ] = socket.assigns.actor_orgs
  end

  test "zero orgs assigns an empty list and nil personal org" do
    # Unreachable through actions (JIT provisioning members the creator);
    # the empty shape is the chrome's defensive state and the test says so.
    user = AccountsFixtures.user!()
    org = AccountsFixtures.personal_org!(user)
    drop_membership!(user, org)

    assert {:cont, socket} = OrgNav.on_mount(:assign_orgs, %{}, %{}, socket_with(user))
    assert socket.assigns.actor_orgs == []
    assert socket.assigns.personal_org_id == nil
    # The handle still resolves — nothing consumes it without rows, and
    # coupling it to memberships would buy nothing.
    assert socket.assigns.username == user.username
  end

  test "no current_user assign degrades to an empty list — data, not a gate" do
    # A miswiring (UserAuth runs first on every sanctioned site) must
    # cost an empty switcher, never a raise.
    assert {:cont, socket} = OrgNav.on_mount(:assign_orgs, %{}, %{}, %Phoenix.LiveView.Socket{})
    assert socket.assigns.actor_orgs == []
    assert socket.assigns.personal_org_id == nil
    assert socket.assigns.username == nil
  end

  test "a nil current_user degrades to an empty list too" do
    socket = Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, :current_user, nil)

    assert {:cont, socket} = OrgNav.on_mount(:assign_orgs, %{}, %{}, socket)
    assert socket.assigns.actor_orgs == []
    assert socket.assigns.personal_org_id == nil
    assert socket.assigns.username == nil
  end

  test "a NULL-username row falls back to the email local part" do
    # Ash.Seed.seed! — the only writer that can produce a NULL-username
    # row (old-pod rolling-window straggler); the create action derives
    # one (state actions can't produce, the documented seed! exception).
    straggler = Ash.Seed.seed!(User, %{email: "straggler@fluxvale.test"})

    assert {:cont, socket} = OrgNav.on_mount(:assign_orgs, %{}, %{}, socket_with(straggler))
    assert socket.assigns.username == "straggler"
  end

  defp socket_with(user) do
    Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, :current_user, user)
  end

  # System-only creates (#119) — the bootstrap posture, mirroring seeds.
  defp team_org!(user) do
    org =
      Organization.create!(
        %{name: "Team Org", slug: "team-#{System.unique_integer([:positive])}"},
        authorize?: false
      )

    Membership.create!(%{organization_id: org.id, user_id: user.id}, authorize?: false)

    org
  end

  defp drop_membership!(user, org) do
    membership =
      Membership
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(user_id == ^user.id and organization_id == ^org.id)
      |> Ash.read_one!(authorize?: false)

    # System posture — the destroy policy is system-only (#119).
    Ash.destroy!(membership, authorize?: false)
  end
end
