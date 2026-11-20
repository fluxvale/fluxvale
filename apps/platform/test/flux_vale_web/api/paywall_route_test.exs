defmodule FluxValeWeb.Api.PaywallRouteTest do
  @moduledoc false

  # #360's Done-when proofs: the money gates bite API callers exactly
  # as they bite the LiveViews. A funded-but-never-paid org (the $3
  # welcome credit) reads its instances but cannot mint backup
  # settings or gateways; a zero-balance org cannot deploy. These are
  # the POLICY refusals (403) — a scope-gate 403 from the PAT slice
  # would be a different failure and must never satisfy these.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Billing.Wallet
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  defp auth(conn, pat), do: put_req_header(conn, "authorization", "Bearer " <> pat)

  defp instance_for!(user) do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()
    InstanceFixtures.instance!(version, user)
  end

  describe "the funded-but-never-paid org (welcome credits never qualify)" do
    test "reads its instances (200) but the paid-once gates refuse the writes (403)", %{
      conn: _conn
    } do
      # ApiPat.member!'s org is JIT-provisioned: 300¢ welcome credit,
      # zero purchases — funded, never paid.
      {user, _pat} = ApiPat.member!()
      pat = ApiPat.mint!(user, ["instances:write", "backups:write", "gateways:write"])
      instance = instance_for!(user)

      list =
        build_conn()
        |> auth(pat)
        |> get("/api/v1/instances")

      assert %{"data" => [_row]} = json_response(list, 200)

      setting =
        build_conn()
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances/#{instance.id}/backup-setting", %{
          "data" => %{
            "type" => "backup_setting",
            "attributes" => %{
              "endpoint" => "https://account.r2.cloudflarestorage.com",
              "bucket" => "fluxvale-kavita",
              "access_key_id" => "AKIAIOSFODNN7EXAMPLE"
            }
          }
        })

      assert %{"errors" => [%{"status" => "403"} | _rest]} = json_response(setting, 403)

      gateway =
        build_conn()
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-gateways", %{
          "data" => %{
            "type" => "access_gateway",
            "attributes" => %{"tailnet_domain" => "example.ts.net", "auth_key" => "tskey-test"}
          }
        })

      assert %{"errors" => [%{"status" => "403"} | _rest]} = json_response(gateway, 403)
    end
  end

  describe "the zero-balance org" do
    test "deploy is refused by the funded gate (403)", %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      org = BillingFixtures.mark_user_paid!(user)

      # The row must exist BEFORE the drain — creation itself needs a
      # funded wallet; the zero-balance proof is about deploy.
      instance = instance_for!(user)
      :ok = BillingFixtures.drain_wallet!(org)

      pat = ApiPat.mint!(user, ["instances:write", "backups:write", "gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> patch("/api/v1/instances/#{instance.id}/deploy", %{
          "data" => %{"type" => "instance", "id" => instance.id, "attributes" => %{}}
        })

      assert %{"errors" => [%{"status" => "403"} | _rest]} = json_response(conn, 403)
    end

    # #362: creation joined the wire — the same gate, proven at the new
    # front door (the zero-balance proof is about CREATE here).
    test "create is refused by the funded gate (403)", %{conn: conn} do
      user = elem(ApiPat.member!(), 0)
      org = BillingFixtures.mark_user_paid!(user)
      :ok = BillingFixtures.drain_wallet!(org)

      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      pat = ApiPat.mint!(user, ["instances:write", "backups:write", "gateways:write"])

      conn =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/instances", %{
          "data" => %{
            "type" => "instance",
            "attributes" => %{"name" => "Zero Balance", "app_version_id" => version.id}
          }
        })

      assert %{"errors" => [%{"status" => "403"} | _rest]} = json_response(conn, 403)
    end
  end

  # ------------------------------------------------------------------
  # The waived zero-balance org — the owner-stack shape (#869)
  # ------------------------------------------------------------------

  describe "the waived zero-balance org — the owner-stack shape (#869)" do
    setup do
      stub_owner_stack()
    end

    test "the machine API builds the owner stack at balance 0 — gateway, domain, three instances",
         %{conn: conn} do
      # The JIT member's org: welcome-funded, never paid. Drain to
      # exactly zero, then flip the operator's waiver — no purchase
      # rows, no balance. Every gate the owner stack reads (funded,
      # paid-once) must answer on the waiver alone.
      user = elem(ApiPat.member!(), 0)
      org = AccountsFixtures.personal_org!(user)
      :ok = BillingFixtures.drain_wallet!(org)

      {:ok, wallet} = Billing.ensure_wallet(org)

      assert {:ok, _wallet} =
               Wallet.set_waiver(wallet, %{paywall_waived: true}, actor: admin())

      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      pat = ApiPat.mint!(user, ["instances:write", "gateways:write"])

      # 1/5 — the gateway (member + funded + paid gates, all on the
      # waiver now).
      gateway =
        conn
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-gateways", %{
          "data" => %{
            "type" => "access_gateway",
            "attributes" => %{
              "tailnet_domain" => "owner.ts.net",
              "auth_key" => "tskey-test",
              "monthly_cents" => 0
            }
          }
        })

      assert %{"data" => %{"attributes" => %{"state" => "provisioning"}}} =
               json_response(gateway, 201)

      # 2/5 — the custom domain (the Certificate mint rides the
      # Kubereq stubs).
      domain =
        build_conn()
        |> auth(pat)
        |> put_req_header("content-type", "application/vnd.api+json")
        |> post("/api/v1/access-domains", %{
          "data" => %{
            "type" => "access_domain",
            "attributes" => %{"domain" => "stack.owner-example.com"}
          }
        })

      assert %{"data" => %{"attributes" => %{"domain" => "stack.owner-example.com"}}} =
               json_response(domain, 201)

      # 3–5/5 — the instances (create is the funded gate alone; three
      # of them, the CLI deploy shape).
      names = ["Stack One", "Stack Two", "Stack Three"]

      for name <- names do
        created =
          build_conn()
          |> auth(pat)
          |> put_req_header("content-type", "application/vnd.api+json")
          |> post("/api/v1/instances", %{
            "data" => %{
              "type" => "instance",
              "attributes" => %{"name" => name, "app_version_id" => version.id}
            }
          })

        assert %{"data" => %{"attributes" => %{"name" => ^name}}} =
                 json_response(created, 201)
      end

      # The whole stack visible on the list. A fresh PAT: the test
      # env's per-token window is 5 requests and the five creates
      # spent them (the instance suite's mint-per-segment stance).
      list_pat = ApiPat.mint!(user, ["instances:write", "gateways:write"])

      listed =
        build_conn()
        |> auth(list_pat)
        |> get("/api/v1/instances")

      assert %{"data" => rows} = json_response(listed, 200)
      listed_names = Enum.map(rows, & &1["attributes"]["name"])

      assert MapSet.new(listed_names) == MapSet.new(names)
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # The owner stack's provider seams, copied from the suites that own
  # each: the gateway create's Tailscale limbs (the gateway suite's
  # setup), the domain register's Certificate mint (the domain suite's
  # Kubereq stubs), the instance namespace apply set (stub_k8s/0, the
  # instance suite's shape).
  defp stub_owner_stack do
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
    stub(Tailscale, :teardown_gateway, fn _gateway -> :ok end)

    # The provider's attach limb plays the row-create and stops there
    # (the attach op suite's own stance).
    stub(Tailscale, :attach_instance, fn gateway, instance ->
      {:ok,
       AccessRoute.create!(
         %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
         authorize?: false
       )}
    end)

    stub(Tailscale, :detach_instance, fn _gateway, _instance -> :ok end)

    # The access-edge limbs (the attach op suite's default stubs).
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :delete, fn _kc, _ns, _n -> {:error, %Error{reason: :not_found}} end)
    stub(Middleware, :delete, fn _kc, _ns, _n -> {:error, %Error{reason: :not_found}} end)

    stub(Kubereq, :attach, fn req, _opts -> req end)
    stub(Kubereq, :apply, fn _req, manifest, _fm -> {:ok, %{status: 201, body: manifest}} end)
    stub(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 200, body: %{}}} end)

    stub(RenderAccessDNS, :call, fn -> :ok end)
    stub(RenderAccessDNS, :call, fn _opts -> :ok end)

    # One wildcard per arity — the instance path passes nil, the
    # gateway/domain paths pass refs.
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    stub_k8s()

    :ok
  end

  # The instance route suite's stub set — the deploy trigger's inline
  # run applies the whole namespace. (Its kubeconfig line rides
  # stub_owner_stack's wildcards above — same function, one stub per
  # arity.)
  defp stub_k8s do
    stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Secret, :create, fn _kc, _ns, _n, _data -> {:ok, %{}} end)
    stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
  end

  # The waiver's flip actor — the has-paid suite's shape (the
  # :set_waiver policy names ActorIsPlatformAdmin).
  defp admin, do: AccountsFixtures.platform_admin!()
end
