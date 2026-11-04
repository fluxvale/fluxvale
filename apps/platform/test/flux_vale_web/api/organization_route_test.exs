defmodule FluxValeWeb.Api.OrganizationRouteTest do
  @moduledoc false

  # #362 T6a: GET /api/v1/organizations — the actor's own orgs. The CLI
  # discovery's source: wallet/access commands need an org id, the panel
  # URL only shows the slug. Scopeless like /me (membership IS the
  # policy — the list_for_actor filter and the read policy compose), so
  # the refusals asserted here are policy-refusals, never the boundary
  # scope gate.

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.ApiPat

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  # A team org (null personal marker) the user joins through the system
  # membership create — both writes are system-only by policy
  # (authorize?: false, the fixtures' precondition posture).
  defp team_org!(member, slug) do
    org =
      Organization.create!(%{name: "Acme", slug: slug}, authorize?: false)

    Membership.create!(%{organization_id: org.id, user_id: member.id}, authorize?: false)

    org
  end

  test "a member lists their organizations — the switcher's key set", %{conn: conn} do
    {user, pat} = ApiPat.member!()
    personal = AccountsFixtures.personal_org!(user)
    team = team_org!(user, "acme-#{System.unique_integer([:positive])}")

    conn =
      conn
      |> auth(pat)
      |> get("/api/v1/organizations")

    assert %{"data" => rows} = json_response(conn, 200)
    ids = for row <- rows, do: row["id"]
    assert personal.id in ids
    assert team.id in ids

    # The key set is the contract (ADR-0019 §1): slug + name per row,
    # the resource id at the resource level — nothing org-internal
    # (personal_owner_id stays private).
    for row <- rows do
      assert row["type"] == "organization"

      keys =
        row["attributes"]
        |> Map.keys()
        |> MapSet.new()

      assert keys == MapSet.new(["slug", "name"])
    end

    personal_row = Enum.find(rows, &(&1["id"] == personal.id))
    assert personal_row["attributes"]["slug"] == personal.slug
    assert personal_row["attributes"]["name"] == personal.name
  end

  test "another member's orgs are not in the list — the filter scopes to the actor", %{
    conn: conn
  } do
    {outsider, outsider_pat} = ApiPat.member!()
    AccountsFixtures.personal_org!(outsider)
    # The foreign org's member needs no token — only their membership row.
    member = AccountsFixtures.user!()
    foreign = team_org!(member, "foreign-#{System.unique_integer([:positive])}")

    conn =
      conn
      |> auth(outsider_pat)
      |> get("/api/v1/organizations")

    assert %{"data" => rows} = json_response(conn, 200)
    ids = for row <- rows, do: row["id"]

    refute foreign.id in ids
    # Only their own orgs come back — at least the personal one.
    refute rows == []
  end

  test "a scopeless token passes — the route is identity-adjacent, :any", %{conn: conn} do
    user = AccountsFixtures.user!()
    personal = AccountsFixtures.personal_org!(user)
    pat = ApiPat.mint!(user.email, [])

    conn =
      conn
      |> auth(pat)
      |> get("/api/v1/organizations")

    assert %{"data" => rows} = json_response(conn, 200)
    assert [row] = rows
    assert row["id"] == personal.id
  end
end
