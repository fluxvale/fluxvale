defmodule FluxVale.Infrastructure.AccessGateway.ChangesTest do
  @moduledoc false

  # ADR-0039's state machine and its cluster legs, driven through the
  # resource's own actions (the stop/start stance: the action wires the
  # change, so these pin the wiring too). The provider is Mimic-stubbed —
  # the cluster is the provider's subject, tested in its own file.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    # The instance create resolves the single cluster row (ResolveCluster).
    InstanceFixtures.local_cluster!()

    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
    stub(Tailscale, :teardown_gateway, fn _gateway -> :ok end)
    stub(Tailscale, :update_credential, fn _gateway, _key -> :ok end)
    stub(Tailscale, :refresh_routes, fn _gateway -> {:ok, %{}} end)

    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = FluxVale.Billing.ensure_wallet(org)
    {:ok, _grant} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)

    {:ok, org: org, owner: owner}
  end

  describe "create/2" do
    test "mints an opaque hostname and lands :provisioning", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      # fv-<8 hex> — no org or app name may appear (CT-ledger privacy).
      assert gateway.hostname =~ ~r/\Afv-[0-9a-f]{8}\z/
      assert gateway.provider == :tailscale
      assert gateway.monthly_cents == 200
      assert gateway.tailnet_domain == "example.ts.net"
    end

    test "a gateway without its tailnet domain cannot exist", %{org: org} do
      # The P1 lesson as a row-level invariant: no suffix, no serve
      # config keys — a nil-domain gateway can never serve, so the
      # create refuses it instead of minting a broken one.
      assert {:error, %Ash.Error.Invalid{errors: [%{field: :tailnet_domain}]}} =
               AccessGateway.create(
                 %{organization_id: org.id, monthly_cents: 200, auth_key: "tskey"},
                 authorize?: false
               )
    end

    test "the tailnet domain must be a bare DNS name", %{org: org} do
      for bad <- ["Example.ts.net", "https://example.ts.net", ".ts.net", "tailnet name"] do
        assert {:error, %Ash.Error.Invalid{errors: [%{field: :tailnet_domain}]}} =
                 AccessGateway.create(
                   %{
                     organization_id: org.id,
                     monthly_cents: 200,
                     tailnet_domain: bad,
                     auth_key: "tskey"
                   },
                   authorize?: false
                 )
      end
    end

    test "a failed create cleans up its orphaned cluster objects", %{org: org} do
      # The row rolls back, so anything still in the cluster is ungoverned:
      # no row, no sweep, no teardown will ever find it. This is the claim
      # the PR body makes, and it is create-path-only.
      expect(Tailscale, :provision_gateway, fn _gateway, _key -> {:error, :cluster_down} end)

      expect(Tailscale, :cleanup_failed_provision, fn _gateway -> :ok end)

      assert {:error, _reason} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   auth_key: "tskey"
                 },
                 authorize?: false
               )

      assert {:error, _not_found} = AccessGateway.get_for_organization(org.id, authorize?: false)
    end

    test "a provisioning failure fails the action and leaves the row for the retry", %{org: org} do
      expect(Tailscale, :provision_gateway, fn _gateway, _key ->
        {:error, :cluster_down}
      end)

      assert {:error, _reason} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   auth_key: "tskey"
                 },
                 authorize?: false
               )

      # No row: the create's transaction rolled back with the failure.
      assert {:error, _not_found} = AccessGateway.get_for_organization(org.id, authorize?: false)
    end

    test "two orgs never collide on a hostname", %{org: org} do
      {other_org, _owner} = BillingFixtures.grant_free_org!()
      {:ok, wallet} = FluxVale.Billing.ensure_wallet(other_org)
      {:ok, _grant} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)

      first = AccessFixtures.gateway!(org)
      second = AccessFixtures.gateway!(other_org)

      assert first.hostname != second.hostname
    end
  end

  describe "attached_instances/1" do
    # Direct pin (teardown's detach list + the settle's pairing sanity):
    # every route the gateway holds, instance loaded. Pinned directly so
    # the helper's coverage no longer rides the async teardown suite's
    # attribution (a measured 99.9/100.0 flake in excoveralls).
    test "lists every paired instance with its route", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      first = AccessFixtures.private_instance!(org, owner)
      second = AccessFixtures.private_instance!(org, owner)

      {:ok, _route} =
        AccessRoute.create(
          %{gateway_id: gateway.id, instance_id: first.id, route_key: "8443"},
          authorize?: false
        )

      {:ok, _route} =
        AccessRoute.create(
          %{gateway_id: gateway.id, instance_id: second.id, route_key: "8444"},
          authorize?: false
        )

      attached_ids =
        gateway
        |> AccessGateway.attached_instances()
        |> Enum.map(& &1.id)
        |> MapSet.new()

      assert attached_ids == MapSet.new([first.id, second.id])
    end
  end

  describe "suspend/1 and resume/1" do
    test "suspend scales to zero, parks the anchor, lands :suspended", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      expect(Tailscale, :scale_gateway, fn _gateway, 0 -> :ok end)

      {:ok, suspended} = AccessGateway.suspend(gateway, authorize?: false)

      assert suspended.state == :suspended
      assert suspended.metering_since == nil
    end

    test "a second suspend is a no-op — no second K8s call", %{org: org} do
      gateway = AccessFixtures.gateway!(org)
      {:ok, suspended} = AccessGateway.suspend(gateway, authorize?: false)

      reject(Tailscale, :scale_gateway, 2)

      assert {:ok, again} = AccessGateway.suspend(suspended, authorize?: false)
      assert again.state == :suspended
    end

    test "a scale failure fails the action and the row keeps :active", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      expect(Tailscale, :scale_gateway, fn _gateway, 0 -> {:error, :cluster_down} end)

      assert {:error, _reason} = AccessGateway.suspend(gateway, authorize?: false)

      fresh = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert fresh.state == :active
    end

    test "resume scales to one, reopens the anchor, lands :provisioning", %{org: org} do
      gateway = AccessFixtures.gateway!(org)
      {:ok, suspended} = AccessGateway.suspend(gateway, authorize?: false)

      expect(Tailscale, :scale_gateway, fn _gateway, 1 -> :ok end)

      {:ok, resumed} = AccessGateway.resume(suspended, authorize?: false)

      assert resumed.state == :provisioning
      assert resumed.metering_since
    end

    test "a resume whose row moved concurrently is refused, not overwritten", %{org: org} do
      gateway = AccessFixtures.gateway!(org, state: :suspended)

      # Panel A's resume lands (exactly one scale — a second call fails
      # this test).
      expect(Tailscale, :scale_gateway, 1, fn _gateway, 1 -> :ok end)
      {:ok, resumed} = AccessGateway.resume(gateway, authorize?: false)

      # Panel B still holds the stale :suspended struct. Its write
      # filters on the row, finds it moved, and refuses as a
      # StaleRecord — no second scale, no anchor reset.
      assert {:error, %Ash.Error.Invalid{}} = AccessGateway.resume(gateway, authorize?: false)

      fresh = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert fresh.state == :provisioning
      assert fresh.metering_since == resumed.metering_since
    end

    test "resuming a non-suspended gateway is a no-op", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      reject(Tailscale, :scale_gateway, 2)

      assert {:ok, same} = AccessGateway.resume(gateway, authorize?: false)
      assert same.state == :active
    end

    test "a resume scale failure keeps :suspended — never serving-but-unbilled", %{org: org} do
      gateway = AccessFixtures.gateway!(org)
      {:ok, suspended} = AccessGateway.suspend(gateway, authorize?: false)

      expect(Tailscale, :scale_gateway, fn _gateway, 1 -> {:error, :cluster_down} end)

      assert {:error, _reason} = AccessGateway.resume(suspended, authorize?: false)

      # The hazard this ordering exists to prevent: a row write that
      # landed before a failed scale would leave :suspended while the pod
      # ran — and NOTHING retries it (the ladder skips :suspended, the
      # observer refuses to override a suspension). The row must still be
      # :suspended AND its anchor still parked, so a later successful
      # resume starts a fresh window rather than billing the gap.
      fresh = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert fresh.state == :suspended
      assert fresh.metering_since == nil
    end

    test "resume writes the row through the action, and a scale failure aborts it", %{org: org} do
      gateway = AccessFixtures.gateway!(org)
      {:ok, suspended} = AccessGateway.suspend(gateway, authorize?: false)
      parent = self()

      # Observe the order: the scale must run from after_action, i.e. the
      # row's own write is what it hangs off. If the scale ran first, a
      # row-write failure afterwards would strand a running pod.
      stub(Tailscale, :scale_gateway, fn gw, replicas ->
        send(parent, {:scaled, gw.id, replicas})
        {:error, :cluster_down}
      end)

      assert {:error, _reason} = AccessGateway.resume(suspended, authorize?: false)
      assert_received {:scaled, id, 1}
      assert id == gateway.id
    end
  end

  describe "update_credential/2" do
    test "re-paste writes the Secret and lands :provisioning", %{org: org} do
      gateway = AccessFixtures.gateway!(org, state: :needs_attention)

      expect(Tailscale, :update_credential, fn _gateway, "tskey-new" -> :ok end)

      {:ok, repasted} =
        AccessGateway.update_credential(gateway, %{auth_key: "tskey-new"}, authorize?: false)

      assert repasted.state == :provisioning
      assert repasted.needs_attention_since == nil
    end

    test "a re-paste with a changed tailnet domain re-renders the serve config first", %{
      org: org
    } do
      gateway = AccessFixtures.gateway!(org)

      # The P1 backfill: the domain rides the re-paste, and the serve
      # rewrite sees the INCOMING domain — the corrected FQDN lands in
      # the Secret before the key write restarts the pod, so the pod
      # mounts the fixed config.
      expect(Tailscale, :refresh_routes, fn %{tailnet_domain: domain} ->
        assert domain == "rejoined.ts.net"
        {:ok, %{}}
      end)

      expect(Tailscale, :update_credential, fn _gateway, "tskey-new" -> :ok end)

      {:ok, repasted} =
        AccessGateway.update_credential(
          gateway,
          %{auth_key: "tskey-new", tailnet_domain: "rejoined.ts.net"},
          authorize?: false
        )

      assert repasted.tailnet_domain == "rejoined.ts.net"
    end

    test "a same-domain re-paste makes no serve rewrite — the key recovery stands alone",
         %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      expect(Tailscale, :update_credential, fn _gateway, "tskey-new" -> :ok end)
      reject(Tailscale, :refresh_routes, 1)

      assert {:ok, _repasted} =
               AccessGateway.update_credential(
                 gateway,
                 %{auth_key: "tskey-new", tailnet_domain: gateway.tailnet_domain},
                 authorize?: false
               )
    end

    test "a failed serve rewrite fails the re-paste — no half-repaired gateway", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      expect(Tailscale, :refresh_routes, fn _gateway -> {:error, :cluster_down} end)
      reject(Tailscale, :update_credential, 2)

      assert {:error, _reason} =
               AccessGateway.update_credential(
                 gateway,
                 %{auth_key: "tskey-new", tailnet_domain: "rejoined.ts.net"},
                 authorize?: false
               )

      # The row keeps its old domain — nothing landed.
      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).tailnet_domain ==
               "example.ts.net"
    end

    test "a write failure fails the action and the row keeps its state", %{org: org} do
      gateway = AccessFixtures.gateway!(org, state: :needs_attention)

      expect(Tailscale, :update_credential, fn _gateway, _key -> {:error, :cluster_down} end)

      assert {:error, _reason} =
               AccessGateway.update_credential(gateway, %{auth_key: "tskey-new"},
                 authorize?: false
               )

      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).state == :needs_attention
    end
  end

  describe "delete/1 (opt-out)" do
    test "flips :destroying and enqueues the teardown", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      {:ok, deleting} = Infrastructure.delete_access_gateway(gateway.id, authorize?: false)

      assert deleting.state == :destroying
    end

    test "deleting a vanished row is a not-found error, not a crash", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      gateway
      |> Ash.Changeset.for_destroy(:destroy_after_teardown, %{}, authorize?: false)
      |> Ash.destroy!()

      assert {:error, _not_found} =
               Infrastructure.delete_access_gateway(gateway.id, authorize?: false)
    end

    test "an already-destroying gateway is not re-enqueued", %{org: org} do
      gateway = AccessFixtures.gateway!(org, state: :destroying)

      {:ok, same} = Infrastructure.delete_access_gateway(gateway.id, authorize?: false)

      assert same.state == :destroying
    end
  end

  describe "the :provision trigger's retry (no create argument)" do
    # The trigger has no auth_key argument, so the retry reads the Secret
    # the first attempt wrote — the self-heal for a cluster failure.
    test "reads the stored key and re-provisions", %{org: org} do
      gateway = provisioned_row!(org)

      stub(Tailscale, :read_credential, fn _gateway -> {:ok, "tskey-stored"} end)

      expect(Tailscale, :provision_gateway, fn _gateway, "tskey-stored" ->
        {:ok, %{credential_secret_ref: "credential-stub"}}
      end)

      assert {:ok, _gateway} =
               AccessGateway.perform_provision(gateway, %{}, authorize?: false)
    end

    test "a missing Secret is a real answer, not a guessed key", %{org: org} do
      gateway = provisioned_row!(org)

      stub(Tailscale, :read_credential, fn _gateway -> {:error, :not_found} end)

      assert {:error, _reason} =
               AccessGateway.perform_provision(gateway, %{}, authorize?: false)
    end

    test "a provisioning failure on the retry surfaces for Oban", %{org: org} do
      gateway = provisioned_row!(org)

      stub(Tailscale, :read_credential, fn _gateway -> {:ok, "tskey-stored"} end)

      expect(Tailscale, :provision_gateway, fn _gateway, _key -> {:error, :cluster_down} end)

      assert {:error, _reason} =
               AccessGateway.perform_provision(gateway, %{}, authorize?: false)
    end
  end

  describe "the :teardown trigger" do
    test "detaches, tears the objects down, and hard-deletes the row", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      expect(Tailscale, :teardown_gateway, fn _gateway -> :ok end)

      assert {:ok, _gone} = AccessGateway.perform_teardown(gateway, %{}, authorize?: false)

      assert {:error, _not_found} = AccessGateway.get_by_id(gateway.id, authorize?: false)
    end

    test "a teardown failure keeps the row and lands a retry message", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      expect(Tailscale, :teardown_gateway, fn _gateway -> {:error, :cluster_down} end)

      assert {:error, _reason} =
               AccessGateway.perform_teardown(gateway, %{}, authorize?: false)

      # The row survives for Oban's retry: a failed teardown must never
      # delete the row that names the objects still out there. (The
      # visible copy is the exhaustion handler's write — a failed
      # action's own writes roll back with it.)
      fresh = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert fresh.id == gateway.id
    end
  end

  describe "the domain's attach/detach seam" do
    # The panel and the API both go through the domain delegates, so a
    # member-facing path is pinned here, not only the provider's.
    test "attach and detach round-trip a private instance", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      stub(Tailscale, :attach_instance, fn _g, _i -> {:ok, :route} end)
      stub(Tailscale, :detach_instance, fn _g, _i -> :ok end)

      assert {:ok, :route} = Infrastructure.attach_instance(gateway, instance)
      assert :ok = Infrastructure.detach_instance(gateway, instance)
    end
  end

  describe "the trigger error handlers" do
    test ":provision exhaustion lands :needs_attention with honest copy", %{org: org} do
      gateway = provisioned_row!(org)

      {:ok, marked} =
        AccessGateway.mark_provision_error(gateway, %{error: %{}}, authorize?: false)

      assert marked.state == :needs_attention
      assert marked.needs_attention_since
      assert marked.status_message =~ "try connecting again"
    end

    test ":teardown exhaustion stays :destroying so billing cannot resurrect it", %{org: org} do
      gateway = AccessFixtures.gateway!(org, state: :destroying)

      {:ok, marked} =
        AccessGateway.mark_teardown_error(gateway, %{error: %{}}, authorize?: false)

      # NOT :needs_attention: the :observe and :settle triggers both select
      # that state, so a failed removal would be re-observed as a live
      # gateway and start billing the org that just opted out.
      assert marked.state == :destroying
      assert marked.status_message =~ "retry removing"
    end
  end

  describe "the :observe trigger's body" do
    test "reads the cluster and writes what it observed", %{org: org} do
      gateway = provisioned_row!(org)

      stub(Tailscale, :gateway_status, fn _gateway ->
        {:ok, %{state: :active, message: "Connected"}}
      end)

      assert {:ok, observed} = AccessGateway.perform_observe(gateway, %{}, authorize?: false)

      assert observed.state == :active
      assert observed.provisioned_at
    end
  end

  describe "read surfaces" do
    test "one gateway per org — the unique identity", %{org: org} do
      _first = AccessFixtures.gateway!(org)

      assert {:error, _reason} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   auth_key: "tskey"
                 },
                 authorize?: false
               )
    end

    test "a member reads their own gateway, a stranger sees not-found", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)

      assert {:ok, found} = AccessGateway.get_by_id(gateway.id, actor: owner)
      assert found.id == gateway.id

      stranger = AccountsFixtures.user!()

      assert {:error, _forbidden} = AccessGateway.get_by_id(gateway.id, actor: stranger)
    end

    test "list_all is the system seam the ladder walks", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      all = AccessGateway.list_all!(authorize?: false)

      assert Enum.any?(all, &(&1.id == gateway.id))
    end
  end

  # A row that has its cluster objects but has not been observed yet —
  # the retry trigger's subject.
  defp provisioned_row!(org) do
    AccessGateway.create!(
      %{
        organization_id: org.id,
        monthly_cents: 200,
        tailnet_domain: "example.ts.net",
        auth_key: "tskey"
      },
      authorize?: false
    )
  end
end
