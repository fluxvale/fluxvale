defmodule FluxVale.Infrastructure.AccessDomain.ChangesTest do
  @moduledoc false

  # ADR-0040 §11's ladder arms, driven through the resource's own
  # actions (the gateway changes_test stance: the action wires the
  # change, so these pin the wiring too). Suspend takes BOTH tails
  # dark — the domain-scoped edge routes and the tailnet claim — and
  # is fail-closed on either. Resume is the owner's funded path: row
  # first, then re-claim (the claim operation's provider path) and
  # re-arm, with the S3 drift on a refused token.

  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  @domain_name "apps.customer.com"
  @resolver_ip "10.43.0.20"
  @missing_token_copy "Your Tailscale API key is missing — paste one to reconnect access"

  setup do
    InstanceFixtures.local_cluster!()

    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
    stub(Tailscale, :teardown_gateway, fn _gateway -> :ok end)
    stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> {:ok, %{device_id: "dev-777"}} end)
    stub(Tailscale, :unclaim_domain, fn _gw, _d -> :ok end)
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)
    Mimic.copy(EdgeRoutes)

    # The suspension funnel's edge leg — default success; the
    # fail-closed test overrides. The resume's re-mint (routes-first,
    # the fix-round ordering) rides the same default.
    stub(EdgeRoutes, :apply_access_none_for_domain, fn _kc, instance, domain ->
      send(self(), {:arms_removed, instance.id, domain.id})
      :ok
    end)

    stub(EdgeRoutes, :apply_access_for_status, fn _kc, _gw, _instance -> :ok end)

    # The S4 hook: a committed claims write re-renders the resolver
    # view best-effort. Default success; expect-ed where a test cares.
    stub(RenderAccessDNS, :call, fn -> :ok end)
    stub(RenderAccessDNS, :call, fn _opts -> :ok end)

    # Domain registration issues the verification Certificate (the
    # claim tests' stubs).
    stub(Kubereq, :attach, fn req, _opts -> req end)
    stub(Kubereq, :apply, fn _req, manifest, _fm -> {:ok, %{status: 201, body: manifest}} end)

    previous = Application.get_env(:flux_vale, :access_dns)
    Application.put_env(:flux_vale, :access_dns, resolver_ip: @resolver_ip)

    on_exit(fn -> Application.put_env(:flux_vale, :access_dns, previous) end)

    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = Billing.ensure_wallet(org)
    {:ok, _grant} = Billing.grant_credits(wallet, 10_000, reason: :adjustment)

    {:ok, org: org, owner: owner}
  end

  describe "suspend — the ladder's honest-dark arm" do
    test "lands :suspended, parks the anchor, and takes both tails dark", %{
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      domain = verified_domain!(owner)
      instance_id = attach_with_hostname!(gateway, org, owner, domain)

      # The claims registry holds the entry the unclaim must drop.
      {:ok, claimed} = Infrastructure.claim_access_domain(gateway, domain, actor: owner)

      stub(EdgeRoutes, :apply_access_none_for_domain, fn _kc, sent_instance, sent_domain ->
        send(self(), {:arms_removed, sent_instance.id, sent_domain.id})
        :ok
      end)

      stub(Tailscale, :unclaim_domain, fn _gw, sent_domain ->
        send(self(), {:unclaimed, sent_domain})
        :ok
      end)

      assert {:ok, suspended} = AccessDomain.mark_suspended(domain, authorize?: false)

      assert suspended.state == :suspended
      # The cursor is parked: the suspended interval cannot bill on
      # resume.
      assert suspended.metering_since == nil

      assert_received {:arms_removed, ^instance_id, domain_id}
      assert domain_id == domain.id
      assert_received {:unclaimed, @domain_name}

      # The claims registry lost the entry.
      fresh = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert Map.has_key?(claimed.dns_claims, @domain_name)
      refute Map.has_key?(fresh.dns_claims || %{}, @domain_name)
    end

    test "fail-closed: a failed route removal leaves the row serving", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      domain = verified_domain!(owner)
      pin_anchor!(domain)
      attach_with_hostname!(gateway, org, owner, domain)

      stub(EdgeRoutes, :apply_access_none_for_domain, fn _kc, _instance, _domain ->
        {:error, :cluster_down}
      end)

      assert {:error, _reason} = AccessDomain.mark_suspended(domain, authorize?: false)

      fresh = AccessDomain.get_by_id!(domain.id, authorize?: false)
      # Still serving, still accruing — the sweep retries.
      assert fresh.state == :verified
      assert fresh.metering_since
    end

    test "fail-closed: a failed unclaim leaves the row serving", %{org: org, owner: owner} do
      _gateway = AccessFixtures.gateway!(org)
      domain = verified_domain!(owner)
      pin_anchor!(domain)

      stub(Tailscale, :unclaim_domain, fn _gw, _d -> {:error, :tailscale_down} end)

      assert {:error, _reason} = AccessDomain.mark_suspended(domain, authorize?: false)

      fresh = AccessDomain.get_by_id!(domain.id, authorize?: false)
      assert fresh.state == :verified
    end

    test "idempotent at :suspended — a re-entered pass is a no-op", %{org: org, owner: owner} do
      _gateway = AccessFixtures.gateway!(org)
      domain = verified_domain!(owner)

      assert {:ok, suspended} = AccessDomain.mark_suspended(domain, authorize?: false)

      # The guard short-circuits before any cluster work; the second
      # pass only re-lands the same state.
      assert {:ok, again} = AccessDomain.mark_suspended(suspended, authorize?: false)
      assert again.state == :suspended
      assert again.metering_since == nil
    end

    test "a platform row is never demoted by a money event (the belt)", %{org: org} do
      platform_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)

      platform =
        AccessDomain.mint_platform!(
          %{domain: platform_domain, organization_id: org.id},
          authorize?: false
        )

      # The ladder's query selects serving :custom rows only; this is
      # the funnel's belt behind it — a platform row bills nothing and
      # must never be parked by the sweep.
      assert {:ok, untouched} = AccessDomain.mark_suspended(platform, authorize?: false)
      assert untouched.state == :verified
    end

    test "an unreachable cluster fails the suspension — fail-closed", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      domain = verified_domain!(owner)
      pin_anchor!(domain)
      attach_with_hostname!(gateway, org, owner, domain)

      stub(K8s, :kubeconfig, fn -> {:error, :no_cluster} end)

      stub(EdgeRoutes, :apply_access_none_for_domain, fn _kc, _instance, _domain ->
        flunk("no cluster, no edge writes")
      end)

      assert {:error, _reason} = AccessDomain.mark_suspended(domain, authorize?: false)

      fresh = AccessDomain.get_by_id!(domain.id, authorize?: false)
      assert fresh.state == :verified
      assert fresh.metering_since
    end

    test "the CoreDNS render follows the COMMITTED suspension only", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      domain = verified_domain!(owner)
      attach_with_hostname!(gateway, org, owner, domain)

      # Failure: the claims write rolled back — the previous view
      # stands, and the render must not run.
      stub(EdgeRoutes, :apply_access_none_for_domain, fn _kc, _instance, _domain ->
        {:error, :cluster_down}
      end)

      stub(RenderAccessDNS, :call, fn -> send(self(), :rendered) end)

      assert {:error, _reason} = AccessDomain.mark_suspended(domain, authorize?: false)
      refute_received :rendered

      # Success: the unclaim committed — the view learns of it.
      stub(EdgeRoutes, :apply_access_none_for_domain, fn _kc, _instance, _domain -> :ok end)

      assert {:ok, _suspended} = AccessDomain.mark_suspended(domain, authorize?: false)
      assert_received :rendered
    end
  end

  describe "resume — the owner's funded path" do
    test "reopens the window, re-claims, and re-arms the routes", %{org: org, owner: owner} do
      gateway = token_gateway!(org)
      domain = verified_domain!(owner)
      instance_id = attach_with_hostname!(gateway, org, owner, domain)

      {:ok, suspended} = AccessDomain.mark_suspended(domain, authorize?: false)

      stub(Tailscale, :claim_domain, fn _gw, sent_domain, _ip ->
        send(self(), {:claimed, sent_domain})
        {:ok, %{device_id: "dev-777"}}
      end)

      stub(EdgeRoutes, :apply_access_for_status, fn _kc, _gw, sent_instance ->
        send(self(), {:rearmed, sent_instance.id})
        :ok
      end)

      before = DateTime.utc_now()

      assert {:ok, resumed} = AccessDomain.resume(suspended, actor: owner)

      assert resumed.state == :verified
      # The accrual window reopened at now (the suspended interval was
      # parked; the resume starts a fresh one).
      assert DateTime.compare(resumed.metering_since, before) != :lt

      # The danger ordering, pinned (BLOCK-2): the route re-mints (the
      # local, idempotent half) BEFORE the tailnet claim (the external
      # write no transaction can roll back) — a route failure never
      # touches the tailnet. assert_received is FIFO.
      assert_received {:rearmed, ^instance_id}
      assert_received {:claimed, @domain_name}

      # The claims registry holds the restored entry.
      fresh = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert fresh.dns_claims[@domain_name]["ip"] == @resolver_ip
    end

    test "the CoreDNS render is success-only and post-commit", %{org: org, owner: owner} do
      gateway = token_gateway!(org)
      domain = verified_domain!(owner)
      attach_with_hostname!(gateway, org, owner, domain)

      {:ok, suspended} = AccessDomain.mark_suspended(domain, authorize?: false)

      # The claim refuses: the resume rolls back, and the ConfigMap
      # must never learn of the uncommitted claims (the S4 lesson).
      stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> {:error, :unauthorized} end)
      stub(RenderAccessDNS, :call, fn -> send(self(), :rendered) end)

      assert {:error, _reason} = AccessDomain.resume(suspended, actor: owner)
      refute_received :rendered

      # The owner pastes the token and retries: the resume commits,
      # and the committed claims reach the view exactly once.
      stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> {:ok, %{device_id: "dev-777"}} end)

      assert {:ok, _resumed} = AccessDomain.resume(suspended, actor: owner)
      assert_received :rendered
    end

    test "a missing token fails the resume, keeps the row parked, and drifts the gateway", %{
      org: org,
      owner: owner
    } do
      gateway = token_gateway!(org)
      domain = verified_domain!(owner)
      attach_with_hostname!(gateway, org, owner, domain)

      {:ok, suspended} = AccessDomain.mark_suspended(domain, authorize?: false)

      stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> {:error, :no_api_token} end)

      assert {:error, _reason} = AccessDomain.resume(suspended, actor: owner)

      # The row is back where the ladder left it (nothing serving,
      # nothing billed) — the one state every other writer respects.
      fresh = AccessDomain.get_by_id!(domain.id, authorize?: false)
      assert fresh.state == :suspended
      assert fresh.metering_since == nil

      # The S3 drift shape: the gateway carries the honest copy.
      drifted = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert drifted.state == :needs_attention
      assert drifted.status_message == @missing_token_copy
    end

    test "a rejected token drifts with the provider's copy", %{org: org, owner: owner} do
      gateway = token_gateway!(org)
      domain = verified_domain!(owner)
      attach_with_hostname!(gateway, org, owner, domain)

      {:ok, suspended} = AccessDomain.mark_suspended(domain, authorize?: false)

      stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> {:error, :unauthorized} end)

      assert {:error, _reason} = AccessDomain.resume(suspended, actor: owner)

      assert AccessDomain.get_by_id!(domain.id, authorize?: false).state == :suspended

      drifted = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert drifted.state == :needs_attention
      assert drifted.status_message == Tailscale.token_drift_message(:unauthorized)
    end

    test "a parked gateway refuses the resume — the tunnel is the prerequisite", %{
      org: org,
      owner: owner
    } do
      gateway = token_gateway!(org)
      domain = verified_domain!(owner)
      attach_with_hostname!(gateway, org, owner, domain)

      {:ok, suspended_domain} = AccessDomain.mark_suspended(domain, authorize?: false)

      # Park the gateway the way the ladder does (its own action, the
      # provider stubbed).
      {:ok, parked} = AccessGateway.suspend(gateway, authorize?: false)
      assert parked.state == :suspended

      stub(Tailscale, :claim_domain, fn _gw, _d, _ip ->
        flunk("a parked gateway claims nothing")
      end)

      assert {:error, _reason} = AccessDomain.resume(suspended_domain, actor: owner)

      assert AccessDomain.get_by_id!(domain.id, authorize?: false).state == :suspended
    end

    test "nothing attached: the resume lands :verified and claims nothing", %{
      org: org,
      owner: owner
    } do
      _gateway = token_gateway!(org)
      domain = verified_domain!(owner)
      {:ok, suspended} = AccessDomain.mark_suspended(domain, authorize?: false)

      stub(Tailscale, :claim_domain, fn _gw, _d, _ip ->
        flunk("a domain with no hostnames claims nothing")
      end)

      assert {:ok, resumed} = AccessDomain.resume(suspended, actor: owner)
      assert resumed.state == :verified
      assert resumed.metering_since
    end

    test "only a suspended domain resumes — a double-click is a no-op", %{org: org, owner: owner} do
      _gateway = token_gateway!(org)
      domain = verified_domain!(owner)

      stub(Tailscale, :claim_domain, fn _gw, _d, _ip ->
        flunk("a serving row re-claims nothing")
      end)

      assert {:ok, unchanged} = AccessDomain.resume(domain, actor: owner)
      assert unchanged.state == :verified
    end

    test "resuming spends money: a drained wallet is Forbidden", %{org: org, owner: owner} do
      _gateway = token_gateway!(org)
      domain = verified_domain!(owner)
      {:ok, suspended} = AccessDomain.mark_suspended(domain, authorize?: false)

      wallet = drained_wallet!(org)

      assert {:error, %Ash.Error.Forbidden{}} =
               AccessDomain.resume(suspended, actor: owner, authorize?: true)

      # The same row resumes the moment the wallet is funded again —
      # the gate is the balance, not the row.
      {:ok, _grant} = Billing.grant_credits(wallet, 10_000, reason: :adjustment)

      assert {:ok, resumed} = AccessDomain.resume(suspended, actor: owner)
      assert resumed.state == :verified
    end

    test "resuming is member-scoped: a non-member is Forbidden", %{org: org, owner: owner} do
      _gateway = token_gateway!(org)
      domain = verified_domain!(owner)
      {:ok, suspended} = AccessDomain.mark_suspended(domain, authorize?: false)

      outsider = AccountsFixtures.user!()
      assert outsider.id != owner.id

      assert {:error, %Ash.Error.Forbidden{}} = AccessDomain.resume(suspended, actor: outsider)
    end

    test "a scope-less token (403) drifts with the scope copy", %{org: org, owner: owner} do
      gateway = token_gateway!(org)
      domain = verified_domain!(owner)
      attach_with_hostname!(gateway, org, owner, domain)

      {:ok, suspended} = AccessDomain.mark_suspended(domain, authorize?: false)

      stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> {:error, :forbidden} end)

      assert {:error, _reason} = AccessDomain.resume(suspended, actor: owner)

      drifted = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert drifted.state == :needs_attention
      assert drifted.status_message == Tailscale.token_drift_message(:forbidden)
    end

    test "an unreachable cluster aborts the resume before anything is touched", %{
      org: org,
      owner: owner
    } do
      gateway = token_gateway!(org)
      domain = verified_domain!(owner)
      attach_with_hostname!(gateway, org, owner, domain)

      {:ok, suspended} = AccessDomain.mark_suspended(domain, authorize?: false)

      stub(K8s, :kubeconfig, fn -> {:error, :no_cluster} end)

      stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> flunk("a dead cluster claims nothing") end)

      assert {:error, _reason} = AccessDomain.resume(suspended, actor: owner)

      assert AccessDomain.get_by_id!(domain.id, authorize?: false).state == :suspended
    end

    test "a gateway read failure (not a miss) aborts the resume honestly", %{
      org: org,
      owner: owner
    } do
      gateway = token_gateway!(org)
      domain = verified_domain!(owner)
      attach_with_hostname!(gateway, org, owner, domain)

      {:ok, suspended} = AccessDomain.mark_suspended(domain, authorize?: false)

      stub(AccessGateway, :get_for_organization, fn _org_id, _opts -> {:error, :db_down} end)

      assert {:error, _reason} = AccessDomain.resume(suspended, actor: owner)

      assert AccessDomain.get_by_id!(domain.id, authorize?: false).state == :suspended
    end

    test "attached instances without a gateway row fail the resume — the drift is not eaten", %{
      org: org,
      owner: owner
    } do
      gateway = token_gateway!(org)
      domain = verified_domain!(owner)
      attach_with_hostname!(gateway, org, owner, domain)

      {:ok, suspended} = AccessDomain.mark_suspended(domain, authorize?: false)

      # The pairing FKs make this shape impossible to persist; a read
      # that reports it anyway is drift, and the resume refuses rather
      # than eat it.
      not_found = %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{resource: AccessGateway}]}
      stub(AccessGateway, :get_for_organization, fn _org_id, _opts -> {:error, not_found} end)

      assert {:error, _reason} = AccessDomain.resume(suspended, actor: owner)

      assert AccessDomain.get_by_id!(domain.id, authorize?: false).state == :suspended
    end

    test "a failed route re-mint fails the resume — fail-closed", %{org: org, owner: owner} do
      gateway = token_gateway!(org)
      domain = verified_domain!(owner)
      attach_with_hostname!(gateway, org, owner, domain)

      {:ok, suspended} = AccessDomain.mark_suspended(domain, authorize?: false)

      stub(EdgeRoutes, :apply_access_for_status, fn _kc, _gw, _instance ->
        {:error, :cluster_down}
      end)

      assert {:error, _reason} = AccessDomain.resume(suspended, actor: owner)

      # The row rolled back to :suspended — no half-armed serve.
      assert AccessDomain.get_by_id!(domain.id, authorize?: false).state == :suspended
    end

    test "a failed drift write never fails the resume over its copy", %{org: org, owner: owner} do
      gateway = token_gateway!(org)
      domain = verified_domain!(owner)
      attach_with_hostname!(gateway, org, owner, domain)

      {:ok, suspended} = AccessDomain.mark_suspended(domain, authorize?: false)

      stub(Tailscale, :claim_domain, fn _gw, _d, _ip -> {:error, :no_api_token} end)
      stub(AccessGateway, :update_state, fn _gw, _attrs, _opts -> {:error, :forced} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, _reason} = AccessDomain.resume(suspended, actor: owner)
        end)

      # The resume's failure is the owner's signal; the copy is
      # best-effort and its failure only logs.
      assert log =~ "token-drift write failed"
      assert AccessDomain.get_by_id!(domain.id, authorize?: false).state == :suspended
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # A wallet drained to ≤ 0 — the gate's refused shape.
  defp drained_wallet!(org) do
    {:ok, wallet} = Billing.ensure_wallet(org)
    {:ok, balance} = Billing.balance(wallet, authorize?: false)
    {:ok, _entry} = Billing.debit_wallet(wallet, balance * 10_000, reason: :adjustment)

    wallet
  end

  # A gateway with the API-token ref recorded (the paste happened) —
  # the resume's re-claim reaches the provider only through it.
  defp token_gateway!(org) do
    gateway = AccessFixtures.gateway!(org)

    AccessGateway.set_api_token_ref!(
      gateway,
      %{api_token_secret_ref: "api-token-secret"},
      authorize?: false
    )
  end

  # A verified :custom domain through the real registration path (the
  # Certificate leg rides the Kubereq stubs).
  defp verified_domain!(owner) do
    {:ok, domain} = Infrastructure.register_access_domain(%{domain: @domain_name}, actor: owner)

    Ash.update!(domain, %{cert_secret_ref: "cert-secret"},
      action: :mark_verified,
      authorize?: false
    )
  end

  defp pin_anchor!(domain) do
    domain
    |> Ash.Changeset.for_update(:settle_anchors, %{metering_since: DateTime.utc_now()},
      authorize?: false
    )
    |> Ash.update!()
  end

  # A private attached instance with one hostname row on the domain —
  # the population the suspend strips and the resume re-arms. Returns
  # the instance's id.
  defp attach_with_hostname!(gateway, org, owner, domain) do
    instance = AccessFixtures.private_instance!(org, owner)

    stub(Tailscale, :attach_instance, fn sent_gateway, sent_instance ->
      {:ok,
       AccessRoute.create!(
         %{gateway_id: sent_gateway.id, instance_id: sent_instance.id, route_key: "8443"},
         authorize?: false
       )}
    end)

    # The access-edge limbs: default success (the attach tests' stubs).
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

    assert {:ok, _route} = Infrastructure.attach_instance(gateway, instance, actor: owner)

    InstanceHostname.mint!(
      %{instance_id: instance.id, access_domain_id: domain.id, label: "app"},
      authorize?: false
    )

    instance.id
  end
end
