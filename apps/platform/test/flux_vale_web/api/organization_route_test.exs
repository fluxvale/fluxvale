defmodule FluxValeWeb.Api.OrganizationRouteTest do
  @moduledoc false

  # #362 T6a + #784: the org wire surface. Reads ride
  # `organizations:read`, writes `organizations:write` — the billing
  # boundary's scope gate above the membership/ownership policies. The
  # cross-org tests ride a full-scope token (a leak must surface as a
  # policy refusal, never hide behind a scope denial).

  use FluxValeWeb.ConnCase, async: true

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.ApiPat

  require Ash.Query

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

  test "the org list needs organizations:read — a read-only token passes, a scopeless one does not",
       %{conn: conn} do
    user = AccountsFixtures.user!()
    personal = AccountsFixtures.personal_org!(user)

    conn =
      conn
      |> auth(ApiPat.mint!(user, ["organizations:read"]))
      |> get("/api/v1/organizations")

    assert %{"data" => rows} = json_response(conn, 200)
    assert [row] = rows
    assert row["id"] == personal.id

    scopeless =
      build_conn()
      |> auth(ApiPat.mint!(user, []))
      |> get("/api/v1/organizations")

    assert %{"errors" => [error]} = json_response(scopeless, 403)
    assert error["detail"] =~ "organizations:read"
  end

  describe "POST /api/v1/organizations (#770)" do
    test "a member creates a team org — the switcher's key set, an owner membership", %{
      conn: conn
    } do
      {user, pat} = ApiPat.member!()
      AccountsFixtures.personal_org!(user)
      slug = "team-#{System.unique_integer([:positive])}"

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/organizations", %{
          "data" => %{
            "type" => "organization",
            "attributes" => %{"name" => "Team", "slug" => slug}
          }
        })

      assert %{"data" => row} = json_response(conn, 201)
      assert row["type"] == "organization"
      assert row["attributes"] == %{"slug" => slug, "name" => "Team"}

      # The action's own transaction wrote the actor's owner
      # membership; the org is a team org (no personal marker).
      org = Organization.get_by_slug!(slug, authorize?: false)
      assert is_nil(org.personal_owner_id)

      assert {:ok, membership} =
               Membership
               |> Ash.Query.filter(organization_id == ^org.id and user_id == ^user.id)
               |> Ash.read_one(authorize?: false)

      assert membership.role == :owner
    end

    test "the reserved-slug list refuses before anything is written", %{conn: conn} do
      {user, pat} = ApiPat.member!()
      AccountsFixtures.personal_org!(user)

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/organizations", %{
          "data" => %{
            "type" => "organization",
            "attributes" => %{"name" => "Docs", "slug" => "docs"}
          }
        })

      assert %{"errors" => [error]} = json_response(conn, 400)
      assert error["detail"] =~ "reserved"
      assert {:error, _reason} = Organization.get_by_slug("docs", authorize?: false)
    end

    test "an admin PAT cannot mint a reserved slug — the blanket stops at the machine API", %{
      conn: conn
    } do
      admin = AccountsFixtures.platform_admin!()
      pat = ApiPat.mint!(admin, ["organizations:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/organizations", %{
          "data" => %{
            "type" => "organization",
            "attributes" => %{"name" => "FluxVale", "slug" => "fluxvale"}
          }
        })

      assert %{"errors" => [error]} = json_response(conn, 400)
      assert error["detail"] =~ "reserved"
      assert {:error, _not_found} = Organization.get_by_slug("fluxvale", authorize?: false)
    end

    test "a duplicate slug is refused with the identity's own words", %{conn: conn} do
      {user, pat} = ApiPat.member!()
      personal = AccountsFixtures.personal_org!(user)

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/organizations", %{
          "data" => %{
            "type" => "organization",
            "attributes" => %{"name" => "Copy", "slug" => personal.slug}
          }
        })

      assert %{"errors" => [error]} = json_response(conn, 400)
      assert error["detail"] == "has already been taken"
    end

    test "a session cookie cannot drive the write", %{conn: conn} do
      user = AccountsFixtures.user!()
      AccountsFixtures.personal_org!(user)
      {:ok, session_token, _claims} = AshAuthentication.Jwt.token_for_user(user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{"user_token" => session_token})
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/organizations", %{
          "data" => %{
            "type" => "organization",
            "attributes" => %{"name" => "Cookie", "slug" => "cookie-org"}
          }
        })

      assert %{"errors" => [error]} = json_response(conn, 401)
      assert error["detail"] =~ "personal access token"
    end
  end

  describe "GET /api/v1/organizations/:id (#784)" do
    test "a member reads the org", %{conn: conn} do
      {user, pat} = ApiPat.member!()
      org = team_org!(user, "read-#{System.unique_integer([:positive])}")

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/organizations/#{org.id}")

      assert %{"data" => row} = json_response(conn, 200)
      assert row["id"] == org.id
      assert row["attributes"]["slug"] == org.slug
      assert row["attributes"]["name"] == org.name
    end

    test "a non-member sees it as not found — the membership policy hides the row", %{conn: conn} do
      {_user, pat} = ApiPat.member!()
      owner = AccountsFixtures.user!()
      org = team_org!(owner, "private-#{System.unique_integer([:positive])}")

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/organizations/#{org.id}")

      assert %{"errors" => [error]} = json_response(conn, 404)
      assert error["code"] == "not_found"
    end

    test "an unknown id is 404", %{conn: conn} do
      {_user, pat} = ApiPat.member!()

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/organizations/#{Ash.UUID.generate()}")

      assert %{"errors" => [_error]} = json_response(conn, 404)
    end

    test "the slug lookup resolves the same row", %{conn: conn} do
      {user, pat} = ApiPat.member!()
      org = team_org!(user, "slug-#{System.unique_integer([:positive])}")

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/organizations/by-slug/#{org.slug}")

      assert %{"data" => row} = json_response(conn, 200)
      assert row["id"] == org.id
    end
  end

  describe "PATCH /api/v1/organizations/:id (#784)" do
    test "the owner renames in place", %{conn: conn} do
      {user, pat} = ApiPat.member!()
      org = team_org!(user, "rename-#{System.unique_integer([:positive])}")

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/organizations/#{org.id}", %{
          "data" => %{
            "type" => "organization",
            "id" => org.id,
            "attributes" => %{"name" => "Renamed"}
          }
        })

      assert %{"data" => row} = json_response(conn, 200)
      assert row["attributes"]["name"] == "Renamed"
      assert {:ok, fresh} = Organization.get_by_id(org.id, authorize?: false)
      assert fresh.name == "Renamed"
    end

    test "a slug change is refused — the wire rename is name-only", %{conn: conn} do
      {user, pat} = ApiPat.member!()
      org = team_org!(user, "slug-locked-#{System.unique_integer([:positive])}")

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/organizations/#{org.id}", %{
          "data" => %{
            "type" => "organization",
            "id" => org.id,
            "attributes" => %{"slug" => "moved"}
          }
        })

      assert %{"errors" => [_error]} = json_response(conn, 400)
      assert {:ok, fresh} = Organization.get_by_id(org.id, authorize?: false)
      assert fresh.slug == org.slug
    end

    test "a non-owner member is forbidden", %{conn: conn} do
      owner = AccountsFixtures.user!()
      org = team_org!(owner, "member-#{System.unique_integer([:positive])}")
      {member, pat} = ApiPat.member!()

      Membership.create!(
        %{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/organizations/#{org.id}", %{
          "data" => %{"type" => "organization", "id" => org.id, "attributes" => %{"name" => "X"}}
        })

      assert %{"errors" => [_error]} = json_response(conn, 403)
    end

    test "a platform admin's token cannot rename a foreign org — the blanket stops at the machine API",
         %{conn: conn} do
      admin = AccountsFixtures.platform_admin!()
      pat = ApiPat.mint!(admin, ["organizations:write", "organizations:read"])
      owner = AccountsFixtures.user!()
      org = team_org!(owner, "foreign-#{System.unique_integer([:positive])}")

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/organizations/#{org.id}", %{
          "data" => %{"type" => "organization", "id" => org.id, "attributes" => %{"name" => "X"}}
        })

      assert %{"errors" => [_error]} = json_response(conn, 404)
    end
  end

  describe "DELETE /api/v1/organizations/:id (#784)" do
    test "the owner deletes an empty org", %{conn: conn} do
      {user, pat} = ApiPat.member!()
      org = team_org!(user, "empty-#{System.unique_integer([:positive])}")

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/organizations/#{org.id}")

      # The access-domain remove shape: a flat body, no JSON:API envelope.
      assert body = json_response(conn, 200)
      assert body["id"] == org.id
      refute Map.has_key?(body, "data")
      assert {:error, _gone} = Organization.get_by_id(org.id, authorize?: false)
    end

    test "a non-owner member is refused with the platform's message", %{conn: conn} do
      {owner, pat} = ApiPat.member!()
      org = team_org!(owner, "blocked-#{System.unique_integer([:positive])}")
      other = AccountsFixtures.user!()

      Membership.create!(
        %{organization_id: org.id, user_id: other.id, role: :member},
        authorize?: false
      )

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/organizations/#{org.id}")

      assert %{"errors" => [error]} = json_response(conn, 400)
      assert error["detail"] =~ "members who are not owners"
      assert {:ok, _still_there} = Organization.get_by_id(org.id, authorize?: false)
    end

    test "a wallet-bearing org is retained with the billing message", %{conn: conn} do
      {user, pat} = ApiPat.member!()
      org = team_org!(user, "wallet-#{System.unique_integer([:positive])}")
      {:ok, _wallet} = FluxVale.Billing.ensure_wallet(org)

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/organizations/#{org.id}")

      assert %{"errors" => [error]} = json_response(conn, 400)
      assert error["detail"] =~ "billing history"
      assert {:ok, _still_there} = Organization.get_by_id(org.id, authorize?: false)
    end

    test "a read-only token cannot delete the billing boundary", %{conn: conn} do
      {user, _full_pat} = ApiPat.member!()
      org = team_org!(user, "readonly-#{System.unique_integer([:positive])}")

      conn =
        conn
        |> auth(ApiPat.mint!(user, ["organizations:read"]))
        |> delete("/api/v1/organizations/#{org.id}")

      assert %{"errors" => [error]} = json_response(conn, 403)
      assert error["detail"] =~ "organizations:write"
      assert {:ok, _still_there} = Organization.get_by_id(org.id, authorize?: false)
    end

    test "a non-member sees it as not found — the membership policy hides the row", %{conn: conn} do
      {_user, pat} = ApiPat.member!()
      owner = AccountsFixtures.user!()
      org = team_org!(owner, "stranger-#{System.unique_integer([:positive])}")

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/organizations/#{org.id}")

      assert %{"errors" => [error]} = json_response(conn, 404)
      assert error["code"] == "not_found"
      assert {:ok, _still_there} = Organization.get_by_id(org.id, authorize?: false)
    end
  end
end
