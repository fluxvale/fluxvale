defmodule FluxValeWeb.AdminAuthorityBoundaryTest do
  @moduledoc false

  # The PAT refusal pinned through the REAL boundary (#644,
  # ADR-0047): the blanket platform-admin authority never rides a
  # token. An admin's PAT with instances:write POSTing an instance for
  # an org the admin does not belong to is refused by the member fence
  # (the marker switches the bypass off); the same admin's PAT keeps
  # today's behavior on resources whose policies carry pure-actor arms
  # (the #140 wallet read) — the surgical scoping D2 demands. Both
  # rungs ride the one boundary: the Phantom /mcp writer retired with
  # its endpoint (ADR-0019 Am. 5).
  #
  # The nested-call families (the P1 fix): generic actions re-read
  # their target through an inner get_by_id that drops the Ash request
  # context — the process mark the boundary sets survives that drop,
  # and the found call sites now propagate the context too. Every
  # family is pinned on the wire: cross-org refused for an admin's
  # token AND a member's token, admitted for the same admin's bare
  # actor.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  # A funded org whose only member is its owner — foreign to the admin.
  defp foreign_org! do
    {org, wallet} = BillingFixtures.funded_wallet!()

    owner =
      org
      |> Ash.load!(:members, authorize?: false)
      |> Map.get(:members)
      |> List.first()

    {org, wallet, owner}
  end

  describe "POST /api/v1/instances — the blanket refuses to ride a PAT" do
    test "an admin's instances:write token cannot create into a foreign org", %{conn: conn} do
      admin = AccountsFixtures.platform_admin!()
      {org, _wallet, _owner} = foreign_org!()
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()
      pat = ApiPat.mint!(admin, ["instances:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances", %{
          "data" => %{
            "type" => "instance",
            "attributes" => %{
              "name" => "Token Admin Deployed",
              "app_version_id" => version.id,
              "organization_id" => org.id
            }
          }
        })

      # The boundary's PAT marker switches the bypass off; the create
      # policy's membership fence (#408) refuses exactly as before the
      # doctrine existed — no god-mode token.
      assert %{"errors" => _details} = json_response(conn, 403)
    end

    test "the same admin actor without token context passes the policy", %{} do
      admin = AccountsFixtures.platform_admin!()
      {org, _wallet, _owner} = foreign_org!()
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      # Direct call, no boundary, no marker: the bypass carries the
      # platform admin in — the doctrine's write widening, pinned from
      # the same fixture shape the refused boundary call used.
      assert {:ok, %Instance{}} =
               Instance.create(
                 %{
                   name: "Console Admin Deployed",
                   app_version_id: version.id,
                   organization_id: org.id
                 },
                 actor: admin,
                 authorize?: true
               )
    end
  end

  describe "GET /api/v1/organizations/:id/wallet — armed resources keep byte-for-byte behavior" do
    test "an admin's wallet:read token reads a foreign wallet exactly as today", %{conn: conn} do
      admin = AccountsFixtures.platform_admin!()
      {_org, wallet, _owner} = foreign_org!()
      pat = ApiPat.mint!(admin, ["wallet:read"])

      conn =
        conn
        |> auth(pat)
        |> get("/api/v1/organizations/#{wallet.organization_id}/wallet")

      # The #140 read arm is a pure actor check — the bypass's refusal
      # changed nothing here, in either direction.
      assert %{"data" => row} = json_response(conn, 200)
      assert row["id"] == wallet.id
    end
  end

  describe "DELETE /api/v1/instances/:id — the reproduced nested-read route" do
    test "an admin's instances:write token cannot delete a foreign instance", %{conn: conn} do
      admin = AccountsFixtures.platform_admin!()
      {_org, _wallet, owner} = foreign_org!()
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()
      instance = InstanceFixtures.instance!(version, owner)
      pat = ApiPat.mint!(admin, ["instances:write"])

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/instances/#{instance.id}")

      # The :delete action re-reads its target through an inner
      # get_by_id that carries no request context — the PROCESS mark
      # the boundary set survives the drop, the fence holds, and the
      # not-found posture is the wire's answer (the P1's 200 is gone).
      assert %{"errors" => _details} = json_response(conn, 404)
    end

    test "a member's token stays refused on the same route", %{conn: conn} do
      {_org, _wallet, owner} = foreign_org!()
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()
      instance = InstanceFixtures.instance!(version, owner)

      stranger = AccountsFixtures.user!()
      pat = ApiPat.mint!(stranger, ["instances:write"])

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/instances/#{instance.id}")

      assert %{"errors" => _details} = json_response(conn, 404)
    end

    test "the same admin actor without token context passes the action", %{} do
      admin = AccountsFixtures.platform_admin!()
      {_org, _wallet, owner} = foreign_org!()
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()
      instance = InstanceFixtures.instance!(version, owner)

      # A never-deployed row hard-deletes synchronously — no marker,
      # bypass live, the doctrine's write widening end to end.
      assert {:ok, deleted} = Instance.delete(instance.id, actor: admin, authorize?: true)
      assert deleted.id == instance.id

      assert {:error, _gone} =
               Instance.get_by_id(instance.id, actor: admin, authorize?: true)
    end
  end

  describe "DELETE /api/v1/access-domains/:id — the wire's removal verb" do
    setup do
      # The domain fixture's register leg mints a Certificate through
      # the cluster stubs (the access-domain route suite's own shape:
      # Kubereq is the dep's own module, stubbed bare).
      InstanceFixtures.local_cluster!()
      stub(Kubereq, :attach, fn req, _opts -> req end)
      stub(Kubereq, :apply, fn _req, manifest, _fm -> {:ok, %{status: 201, body: manifest}} end)
      stub(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 200, body: %{}}} end)
      stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
      stub(RenderAccessDNS, :call, fn -> :ok end)
      :ok
    end

    test "an admin's gateways:write token cannot remove a foreign domain", %{conn: conn} do
      admin = AccountsFixtures.platform_admin!()
      {org, _wallet, owner} = foreign_org!()

      domain =
        AccessDomain
        |> Ash.Changeset.for_create(
          :register,
          %{
            domain: "admin-authority-#{System.unique_integer()}.example.com",
            organization_id: org.id
          },
          actor: owner,
          authorize?: false
        )
        |> Ash.create!()

      pat = ApiPat.mint!(admin, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/access-domains/#{domain.id}")

      assert %{"errors" => _details} = json_response(conn, 404)
    end

    test "a member's token stays refused on the same route", %{conn: conn} do
      {org, _wallet, owner} = foreign_org!()

      domain =
        AccessDomain
        |> Ash.Changeset.for_create(
          :register,
          %{
            domain: "member-fence-#{System.unique_integer()}.example.com",
            organization_id: org.id
          },
          actor: owner,
          authorize?: false
        )
        |> Ash.create!()

      stranger = AccountsFixtures.user!()
      pat = ApiPat.mint!(stranger, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/access-domains/#{domain.id}")

      assert %{"errors" => _details} = json_response(conn, 404)
    end

    # The bare-actor arm rides its OWN test: a boundary call through
    # the test process leaves the conservative process mark behind
    # (the check's moduledoc leak note), and the no-marker proof must
    # not run under it.
    test "the same admin actor without token context passes the fence", %{} do
      admin = AccountsFixtures.platform_admin!()
      {org, _wallet, owner} = foreign_org!()

      domain =
        AccessDomain
        |> Ash.Changeset.for_create(
          :register,
          %{
            domain: "bare-actor-#{System.unique_integer()}.example.com",
            organization_id: org.id
          },
          actor: owner,
          authorize?: false
        )
        |> Ash.create!()

      # The :remove_via_api action has no policy of its own — its
      # authorized inner get_by_id IS the fence (#482 P2's stance), so
      # the bare-actor admission pins exactly there; the operation
      # past the fence is the access-domain route suite's coverage.
      assert {:ok, row} =
               AccessDomain.get_by_id(domain.id,
                 actor: admin,
                 authorize?: true
               )

      assert row.id == domain.id
    end
  end

  describe "POST and DELETE /api/v1/access-gateways/:id/attachments — the pairing verbs" do
    setup do
      # The gateway route suite's stub lattice — the fixtures and the
      # direct-action arms walk the same provider and access-edge
      # limbs that suite exercises.
      alias FluxVale.Clients.K8s.Error
      alias FluxVale.Clients.K8s.Resources.Ingress
      alias FluxVale.Clients.K8s.Resources.Middleware
      alias FluxVale.Clients.K8s.Resources.NetworkPolicy
      alias FluxVale.Clients.K8s.Resources.Service

      InstanceFixtures.local_cluster!()

      stub(Tailscale, :provision_gateway, fn _gateway, _key ->
        {:ok, %{credential_secret_ref: "credential-stub"}}
      end)

      stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
      stub(Tailscale, :teardown_gateway, fn _gateway -> :ok end)

      stub(Tailscale, :attach_instance, fn gateway, instance ->
        {:ok,
         AccessRoute.create!(
           %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
           authorize?: false
         )}
      end)

      stub(Tailscale, :detach_instance, fn _gateway, _instance -> :ok end)

      stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
      stub(Ingress, :delete, fn _kc, _ns, _n -> {:error, %Error{reason: :not_found}} end)
      stub(Middleware, :delete, fn _kc, _ns, _n -> {:error, %Error{reason: :not_found}} end)
      stub(RenderAccessDNS, :call, fn -> :ok end)
      stub(RenderAccessDNS, :call, fn _opts -> :ok end)
      stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

      :ok
    end

    test "an admin's gateways:write token cannot attach across orgs", %{conn: conn} do
      admin = AccountsFixtures.platform_admin!()
      {org, _wallet, owner} = foreign_org!()
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)
      pat = ApiPat.mint!(admin, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-gateways/#{gateway.id}/attachments", %{
          "data" => %{"instance_id" => instance.id}
        })

      # Both inner get_by_id reads (gateway, then instance) refuse the
      # token; the first answers the not-found posture.
      assert %{"errors" => _details} = json_response(conn, 404)
    end

    test "an admin's token cannot detach another org's pairing either", %{conn: conn} do
      admin = AccountsFixtures.platform_admin!()
      {org, _wallet, owner} = foreign_org!()
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)
      pat = ApiPat.mint!(admin, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> delete("/api/v1/access-gateways/#{gateway.id}/attachments/#{instance.id}")

      assert %{"errors" => _details} = json_response(conn, 404)
    end

    test "a member's token stays refused on the pairing verbs", %{conn: conn} do
      {org, _wallet, owner} = foreign_org!()
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      stranger = AccountsFixtures.user!()
      pat = ApiPat.mint!(stranger, ["gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-gateways/#{gateway.id}/attachments", %{
          "data" => %{"instance_id" => instance.id}
        })

      assert %{"errors" => _details} = json_response(conn, 404)
    end

    test "the same admin actor without token context attaches and detaches the foreign pair",
         %{} do
      admin = AccountsFixtures.platform_admin!()
      {org, _wallet, owner} = foreign_org!()
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      attach =
        Ash.ActionInput.for_action(
          AccessGateway,
          :attach_instance,
          %{gateway_id: gateway.id, instance_id: instance.id},
          actor: admin,
          authorize?: true
        )

      assert {:ok, %AccessRoute{gateway_id: gateway_id}} = Ash.run_action(attach)
      assert gateway_id == gateway.id

      detach =
        Ash.ActionInput.for_action(
          AccessGateway,
          :detach_instance,
          %{gateway_id: gateway.id, instance_id: instance.id},
          actor: admin,
          authorize?: true
        )

      assert :ok = Ash.run_action(detach)
    end
  end
end
