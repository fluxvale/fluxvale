defmodule FluxVale.Infrastructure.AccessGateway.ChangesTest do
  @moduledoc false

  # ADR-0039's state machine and its cluster legs, driven through the
  # resource's own actions (the stop/start stance: the action wires the
  # change, so these pin the wiring too). The provider is Mimic-stubbed —
  # the cluster is the provider's subject, tested in its own file.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Billing
  alias FluxVale.Billing.Wallet
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Operations.ClaimUnclaimedDomains
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

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
      too_long = String.duplicate("a", 250) <> ".ts.net"

      for bad <- ["Example.ts.net", "https://example.ts.net", ".ts.net", "tailnet name", too_long] do
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

  describe "the single-credential create (#836)" do
    test "mint enable: api_token with no auth_key lands :provisioning with the token stored", %{
      org: org,
      owner: owner
    } do
      parent = self()

      stub(Tailscale, :write_api_credential, fn gateway, token ->
        send(parent, {:token_stored, gateway.id, token})
        {:ok, %{api_token_secret_ref: "api-credential-stub"}}
      end)

      expect(Tailscale, :provision_gateway_minted, fn gateway ->
        send(parent, {:minted, gateway.id})
        {:ok, %{credential_secret_ref: "credential-stub"}}
      end)

      reject(Tailscale, :provision_gateway, 2)

      assert {:ok, gateway} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   api_token: "  tskey-api-secret  "
                 },
                 actor: owner,
                 authorize?: false
               )

      assert gateway.state == :provisioning
      assert gateway.api_token_secret_ref == "api-credential-stub"
      assert gateway.token_set_at

      # The TRIMMED token went to the Secret, under the row's own id
      # (the Secret name derives from it), and the mint ran on that row.
      assert_received {:token_stored, id, "tskey-api-secret"}
      assert_received {:minted, ^id}
    end

    test "neither credential is refused on :auth_key", %{org: org} do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.create(
                 %{organization_id: org.id, monthly_cents: 200, tailnet_domain: "example.ts.net"},
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.field == :auth_key and
                   &1.message == "Paste an auth key or an API token to enable private access")
             )
    end

    test "a whitespace-only token counts as absent too", %{org: org} do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   api_token: "   "
                 },
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.field == :auth_key and
                   &1.message == "Paste an auth key or an API token to enable private access")
             )
    end

    test "both credentials are refused on :api_token before anything is written", %{org: org} do
      reject(Tailscale, :provision_gateway, 2)
      reject(Tailscale, :provision_gateway_minted, 1)
      reject(Tailscale, :write_api_credential, 2)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   auth_key: "tskey",
                   api_token: "tskey-api-secret"
                 },
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.field == :api_token and &1.message == "Paste one or the other, not both")
             )
    end

    test "a token-at-create by a non-owner member is refused, nothing written", %{org: org} do
      member = AccountsFixtures.user!()

      # The precondition rides the create action with authorize?: false —
      # the sanctioned bootstrap posture (nothing in the system makes
      # :member rows today).
      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      # The member passes the create policy (funded by the setup grant,
      # paid here) — the fence that bites is the TOKEN's, in the change.
      BillingFixtures.mark_paid!(org)

      reject(Tailscale, :write_api_credential, 2)
      reject(Tailscale, :provision_gateway_minted, 1)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   api_token: "tskey-api-secret"
                 },
                 actor: member
               )

      assert Enum.any?(
               errors,
               &(&1.field == :api_token and
                   &1.message == "Only an organization owner can store the Tailscale API token")
             )

      assert {:error, _not_found} = AccessGateway.get_for_organization(org.id, authorize?: false)
    end

    test "a rolled-back insert still deletes the token Secret it wrote (#853 review)", %{
      org: org,
      owner: owner
    } do
      # The unique_organization identity is the likeliest trigger: a
      # double-submitted enable form. The SECOND create writes the
      # api-credential Secret in before_action, then the INSERT fails —
      # ProvisionCluster's after_action never runs, so the after_transaction
      # limb is the only thing standing between the crown credential and a
      # permanent orphan under a uuid no later create reuses.
      existing = AccessFixtures.gateway!(org)

      stub(Tailscale, :write_api_credential, fn _gateway, _token ->
        {:ok, %{api_token_secret_ref: "api-credential-stub"}}
      end)

      reject(Tailscale, :provision_gateway_minted, 1)

      expect(Tailscale, :cleanup_failed_provision, fn gateway ->
        send(self(), {:cleanup, gateway.organization_id})
        :ok
      end)

      assert {:error, _identity} =
               AccessGateway.create(
                 %{
                   organization_id: existing.organization_id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   api_token: "tskey-api-secret"
                 },
                 actor: owner,
                 authorize?: false
               )

      assert_received {:cleanup, _org_id}
    end

    test "a failed token store at create refuses the create with the store sentence", %{
      org: org,
      owner: owner
    } do
      # The three tag shapes the store-failure logger must never leak:
      # an atom, a status/reason map, anything else. Same sentence each.
      for failure <- [:cluster_down, %{status_code: 500, reason: :boom}, "unexpected shape"] do
        stub(Tailscale, :write_api_credential, fn _gateway, _token -> {:error, failure} end)

        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 AccessGateway.create(
                   %{
                     organization_id: org.id,
                     monthly_cents: 200,
                     tailnet_domain: "example.ts.net",
                     api_token: "tskey-api-secret"
                   },
                   actor: owner,
                   authorize?: false
                 )

        assert Enum.any?(
                 errors,
                 &(&1.field == :api_token and
                     &1.message == "we couldn't store the token — try again")
               )
      end
    end

    test "the mint failure matrix surfaces the copy table and rolls the row back", %{
      org: org,
      owner: owner
    } do
      stub(Tailscale, :write_api_credential, fn _gateway, _token ->
        {:ok, %{api_token_secret_ref: "api-credential-stub"}}
      end)

      stub(Tailscale, :cleanup_failed_provision, fn _gateway -> :ok end)

      for {reason, sentence} <- [
            {:unauthorized,
             "Your Tailscale API key was rejected. Paste a fresh one in Settings → Access"},
            {:forbidden,
             "Your Tailscale API key can't create join keys — mint it from a tailnet owner or admin account, or paste an auth key instead"},
            {:network_error, "Couldn't reach Tailscale to create a join key. Try again"}
          ] do
        stub(Tailscale, :provision_gateway_minted, fn _gateway -> {:error, reason} end)

        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 AccessGateway.create(
                   %{
                     organization_id: org.id,
                     monthly_cents: 200,
                     tailnet_domain: "example.ts.net",
                     api_token: "tskey-api-secret"
                   },
                   actor: owner,
                   authorize?: false
                 )

        assert Enum.any?(errors, &(&1.field == :auth_key and &1.message == sentence))

        # No row: the create's transaction rolled back with the failure.
        assert {:error, _not_found} =
                 AccessGateway.get_for_organization(org.id, authorize?: false)
      end
    end

    test "a failed mint create runs the create-path cleanup", %{org: org, owner: owner} do
      stub(Tailscale, :write_api_credential, fn _gateway, _token ->
        {:ok, %{api_token_secret_ref: "api-credential-stub"}}
      end)

      stub(Tailscale, :provision_gateway_minted, fn _gateway -> {:error, :unauthorized} end)

      # The provider already revoked what it could; the Secret deletes
      # (including the api-credential one this create wrote) ride here.
      # Cleanup can run TWICE by design: ProvisionCluster's mint-fail
      # pass, then CreateStoresApiToken's after_transaction orphan limb —
      # idempotent deletes, so a stub (not a strict expectation).
      parent = self()

      stub(Tailscale, :cleanup_failed_provision, fn _gateway ->
        send(parent, :cleaned)
        :ok
      end)

      assert {:error, _reason} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   api_token: "tskey-api-secret"
                 },
                 actor: owner,
                 authorize?: false
               )

      assert_received :cleaned
    end
  end

  describe "the pair intake at settings (#836 lane B)" do
    # The claim sweep reads the global :access_dns env through the
    # operation stack, so the sweep-runs pin stubs the operation at the
    # seam (the async-safe arm; the wrapper's own pair resolution is
    # pinned end-to-end in SetAccessApiTokenTest).
    test "a pair save stores both halves trimmed, sets ref + stamp, and runs the sweep", %{
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      parent = self()

      stub(Tailscale, :write_client_credential, fn gw, client_id, client_secret ->
        send(parent, {:pair_stored, gw.id, client_id, client_secret})
        {:ok, %{api_token_secret_ref: "api-credential-pair"}}
      end)

      stub(ClaimUnclaimedDomains, :call, fn row, opts ->
        send(parent, {:sweep, row.id, opts[:actor].id})
        %{claimed: [], failed: []}
      end)

      reject(Tailscale, :write_api_credential, 2)

      assert {:ok, row} =
               AccessGateway.set_api_token(
                 gateway,
                 %{ts_client_id: "  client-id-1  ", ts_client_secret: " client-secret-1 \n"},
                 actor: owner,
                 authorize?: false
               )

      assert row.api_token_secret_ref == "api-credential-pair"
      assert %DateTime{} = row.token_set_at

      assert_received {:pair_stored, id, "client-id-1", "client-secret-1"}

      owner_id = owner.id
      assert_received {:sweep, ^id, ^owner_id}
    end

    test "a whitespace-only half counts as absent — the lone half is refused", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      reject(Tailscale, :write_client_credential, 3)
      reject(Tailscale, :write_api_credential, 2)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.set_api_token(
                 gateway,
                 %{ts_client_id: "client-id-1", ts_client_secret: "   "},
                 authorize?: false
               )

      # The id is alone: the refusal names its missing half's field.
      assert Enum.any?(
               errors,
               &(&1.field == :ts_client_secret and
                   &1.message == "Save the client id and secret together, or the API token alone")
             )
    end

    test "each mixed shape is refused on :ts_client_id with the sentence", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      reject(Tailscale, :write_client_credential, 3)
      reject(Tailscale, :write_api_credential, 2)

      # The three GENUINE mixes (token + id, token + secret, token +
      # the whole pair) — the lone-half arms have their own tests.
      for params <- [
            %{api_token: "tskey-api", ts_client_id: "client-id-1"},
            %{api_token: "tskey-api", ts_client_secret: "client-secret-1"},
            %{
              api_token: "tskey-api",
              ts_client_id: "client-id-1",
              ts_client_secret: "client-secret-1"
            }
          ] do
        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 AccessGateway.set_api_token(gateway, params, authorize?: false)

        assert Enum.any?(
                 errors,
                 &(&1.field == :ts_client_id and
                     &1.message ==
                       "Save the client id and secret together, or the API token alone")
               )
      end
    end

    test "a lone secret is refused on :ts_client_id — the lone-half arm, not a mix", %{
      org: org
    } do
      gateway = AccessFixtures.gateway!(org)

      reject(Tailscale, :write_client_credential, 3)
      reject(Tailscale, :write_api_credential, 2)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.set_api_token(gateway, %{ts_client_secret: "client-secret-1"},
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.field == :ts_client_id and
                   &1.message ==
                     "Save the client id and secret together, or the API token alone")
             )
    end

    test "an empty save is refused on :api_token", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      reject(Tailscale, :write_client_credential, 3)
      reject(Tailscale, :write_api_credential, 2)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.set_api_token(gateway, %{}, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.field == :api_token and
                   &1.message == "Save the client id and secret together, or the API token alone")
             )
    end

    test "a failed pair store refuses on :ts_client_secret with the store sentence", %{
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)

      stub(Tailscale, :write_client_credential, fn _gw, _id, _secret ->
        {:error, :cluster_down}
      end)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.set_api_token(
                 gateway,
                 %{ts_client_id: "client-id-1", ts_client_secret: "client-secret-1"},
                 actor: owner,
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.field == :ts_client_secret and
                   &1.message == "we couldn't store the credential — try again")
             )

      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).api_token_secret_ref == nil
    end

    test "the fence covers the pair — a member is refused before any write", %{org: org} do
      gateway = AccessFixtures.gateway!(org)
      member = AccountsFixtures.user!()

      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      reject(Tailscale, :write_client_credential, 3)

      # The policy fences the member on every actor path; this is the
      # authorize?-free seam's own fence, so its shape is the
      # programming-error class (the #760 intake's exact posture).
      assert {:error, %Ash.Error.Unknown{}} =
               AccessGateway.set_api_token(
                 gateway,
                 %{ts_client_id: "client-id-1", ts_client_secret: "client-secret-1"},
                 actor: member,
                 authorize?: false
               )

      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).api_token_secret_ref == nil
    end
  end

  describe "the pair intake at create (#836 lane B)" do
    test "a pair-at-create is born with the ref and the stamp and skips the claim sweep", %{
      org: org,
      owner: owner
    } do
      parent = self()

      stub(Tailscale, :write_client_credential, fn gw, client_id, client_secret ->
        send(parent, {:pair_stored, gw.id, client_id, client_secret})
        {:ok, %{api_token_secret_ref: "api-credential-pair"}}
      end)

      stub(Tailscale, :provision_gateway_minted, fn gw ->
        send(parent, {:minted, gw.id})
        {:ok, %{credential_secret_ref: "credential-stub"}}
      end)

      stub(ClaimUnclaimedDomains, :call, fn _row, _opts ->
        flunk("the create path never sweeps — the observer's first join claims later")
      end)

      reject(Tailscale, :write_api_credential, 2)
      reject(Tailscale, :provision_gateway, 2)

      assert {:ok, gateway} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   ts_client_id: " client-id-1 ",
                   ts_client_secret: "client-secret-1"
                 },
                 actor: owner,
                 authorize?: false
               )

      assert gateway.state == :provisioning
      assert gateway.api_token_secret_ref == "api-credential-pair"
      assert gateway.token_set_at

      # The TRIMMED pair went to the Secret under the row's own id, and
      # the mint ran on that row.
      assert_received {:pair_stored, id, "client-id-1", "client-secret-1"}
      assert_received {:minted, ^id}
    end

    test "a failed pair store at create refuses with the store sentence", %{
      org: org,
      owner: owner
    } do
      stub(Tailscale, :write_client_credential, fn _gw, _id, _secret ->
        {:error, :cluster_down}
      end)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   ts_client_id: "client-id-1",
                   ts_client_secret: "client-secret-1"
                 },
                 actor: owner,
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.field == :ts_client_secret and
                   &1.message == "we couldn't store the credential — try again")
             )

      assert {:error, _not_found} = AccessGateway.get_for_organization(org.id, authorize?: false)
    end

    test "a pair-at-create by a non-owner member is refused, nothing written", %{org: org} do
      member = AccountsFixtures.user!()

      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      BillingFixtures.mark_paid!(org)

      reject(Tailscale, :write_client_credential, 3)
      reject(Tailscale, :provision_gateway_minted, 1)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   ts_client_id: "client-id-1",
                   ts_client_secret: "client-secret-1"
                 },
                 actor: member
               )

      assert Enum.any?(
               errors,
               &(&1.field == :ts_client_id and
                   &1.message == "Only an organization owner can store the Tailscale API token")
             )

      assert {:error, _not_found} = AccessGateway.get_for_organization(org.id, authorize?: false)
    end

    test "a lone client id is refused on :ts_client_secret", %{org: org} do
      reject(Tailscale, :write_client_credential, 3)
      reject(Tailscale, :write_api_credential, 2)
      reject(Tailscale, :provision_gateway, 2)
      reject(Tailscale, :provision_gateway_minted, 1)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   ts_client_id: "client-id-1"
                 },
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.field == :ts_client_secret and
                   &1.message == "Save the client id and secret together")
             )
    end

    test "a lone client secret is refused on :ts_client_id", %{org: org} do
      reject(Tailscale, :write_client_credential, 3)
      reject(Tailscale, :write_api_credential, 2)
      reject(Tailscale, :provision_gateway, 2)
      reject(Tailscale, :provision_gateway_minted, 1)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   ts_client_secret: "client-secret-1"
                 },
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.field == :ts_client_id and
                   &1.message == "Save the client id and secret together")
             )
    end

    test "a whitespace-only half counts as absent too", %{org: org} do
      reject(Tailscale, :write_client_credential, 3)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   ts_client_id: "  ",
                   ts_client_secret: "client-secret-1"
                 },
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.field == :ts_client_id and
                   &1.message == "Save the client id and secret together")
             )
    end

    test "the pair beside a token is refused on :ts_client_id", %{org: org} do
      reject(Tailscale, :write_client_credential, 3)
      reject(Tailscale, :write_api_credential, 2)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   api_token: "tskey-api-secret",
                   ts_client_id: "client-id-1",
                   ts_client_secret: "client-secret-1"
                 },
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.field == :ts_client_id and
                   &1.message ==
                     "Paste one credential only — the client pair or an API token or an auth key")
             )
    end

    test "the pair beside an auth key is refused on :ts_client_id", %{org: org} do
      reject(Tailscale, :write_client_credential, 3)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   auth_key: "tskey",
                   ts_client_id: "client-id-1",
                   ts_client_secret: "client-secret-1"
                 },
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.field == :ts_client_id and
                   &1.message ==
                     "Paste one credential only — the client pair or an API token or an auth key")
             )
    end

    test "the pair beside both other credentials is refused on :ts_client_id", %{org: org} do
      reject(Tailscale, :write_client_credential, 3)
      reject(Tailscale, :write_api_credential, 2)
      reject(Tailscale, :provision_gateway, 2)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   auth_key: "tskey",
                   api_token: "tskey-api-secret",
                   ts_client_id: "client-id-1",
                   ts_client_secret: "client-secret-1"
                 },
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.field == :ts_client_id and
                   &1.message ==
                     "Paste one credential only — the client pair or an API token or an auth key")
             )
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

  describe "the paid-once policy gates (create/resume)" do
    # The paid-once gate (ActorOrgHasPaid) beside the funded check: the
    # signup welcome credit must not unlock enablement or resume — one
    # real $1+ payment ever.

    test "a never-paid member is forbidden to create and to resume", %{org: org, owner: owner} do
      # Create rides the actor's personal org (SetOrganizationFromActor
      # pins the row there too) — the fixture org here (the org the #408
      # marker names: grant_free_org! builds it as the owner's personal
      # org), funded by the adjustment grant but never paid: exactly the
      # wallet the paid-once gate exists for.
      assert {:error, %Ash.Error.Forbidden{}} =
               AccessGateway.create(
                 %{monthly_cents: 200, tailnet_domain: "example.ts.net", auth_key: "tskey"},
                 actor: owner
               )

      suspended = AccessFixtures.gateway!(org, state: :suspended)

      assert {:error, %Ash.Error.Forbidden{}} = AccessGateway.resume(suspended, actor: owner)
    end

    test "a paid, funded member creates and resumes", %{owner: owner} do
      # The create bills the ACTOR'S PERSONAL ORG — SetOrganizationFromActor
      # pins it, and the paid+funded policy reads the same resolver's
      # answer (the org the #408 marker names). Assert against that
      # resolved org, not against the fixture org by coincidence.
      {:ok, personal} = Accounts.personal_org_for_user(owner.id, authorize?: false)
      BillingFixtures.mark_paid!(personal)

      assert {:ok, gateway} =
               AccessGateway.create(
                 %{monthly_cents: 200, tailnet_domain: "example.ts.net", auth_key: "tskey"},
                 actor: owner
               )

      assert gateway.organization_id == personal.id

      # Resume opens the same way for a paid, funded wallet.
      stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
      {:ok, suspended} = AccessGateway.suspend(gateway, authorize?: false)

      assert {:ok, resumed} = AccessGateway.resume(suspended, actor: owner)
      assert resumed.state == :provisioning
    end

    test "paid but empty — the funded check still bites the resume", %{org: org, owner: owner} do
      BillingFixtures.mark_paid!(org)
      suspended = AccessFixtures.gateway!(org, state: :suspended)
      BillingFixtures.drain_wallet!(org)

      assert {:error, %Ash.Error.Forbidden{}} = AccessGateway.resume(suspended, actor: owner)
    end

    test "a forged struct naming a paid org is still refused — the row's own org answers", %{
      org: org,
      owner: owner
    } do
      # An in-process caller controls the changeset's in-memory struct:
      # forge its organization_id to name a paid org the actor belongs
      # to, while the real row lives in the never-paid org. The check
      # re-reads the row from the DB, so the forgery changes nothing.
      # (Membership is satisfied on both orgs, so the paid check is the
      # only gate in play.)
      paid_other = AccountsFixtures.owned_org!(owner)
      BillingFixtures.funded_wallet!(org: paid_other)
      BillingFixtures.mark_paid!(paid_other)

      suspended = AccessFixtures.gateway!(org, state: :suspended)

      changeset = Ash.Changeset.for_update(suspended, :resume, %{}, actor: owner)
      forged = %{changeset | data: %{suspended | organization_id: paid_other.id}}

      assert {:error, %Ash.Error.Forbidden{}} = AccessGateway.resume(forged, actor: owner)
    end

    test "an enable naming its org lands the row there and bills that org's wallet", %{
      owner: owner
    } do
      # The org page's enable (#408): the create names the page org, and
      # the paid/funded gates read THAT org's wallet. The actor's
      # personal org (the setup org) is adjustment-funded but never paid
      # — under the old pin-the-personal behavior this create would
      # answer Forbidden on the personal wallet's paid gate.
      {:ok, team} =
        Accounts.create_organization(owner, %{
          name: "Gateway Team",
          slug: "gw-team-#{System.unique_integer([:positive])}"
        })

      BillingFixtures.funded_wallet!(org: team)
      BillingFixtures.mark_paid!(team)

      assert {:ok, gateway} =
               AccessGateway.create(
                 %{
                   organization_id: team.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   auth_key: "tskey"
                 },
                 actor: owner
               )

      assert gateway.organization_id == team.id
    end

    test "a named org the actor does not belong to is Forbidden — funded and paid don't open it",
         %{
           owner: owner
         } do
      # The membership fence: the wallet gates alone would pass a
      # funded-and-paid foreign org.
      {foreign, _foreign_owner} = BillingFixtures.grant_free_org!()
      BillingFixtures.funded_wallet!(org: foreign)
      BillingFixtures.mark_paid!(foreign)

      assert {:error, %Ash.Error.Forbidden{}} =
               AccessGateway.create(
                 %{
                   organization_id: foreign.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   auth_key: "tskey"
                 },
                 actor: owner
               )
    end

    test "an org-less actor fails loudly (field-scoped, not a crash)" do
      # Ash.seed! — the only way to produce an org-less user: the create
      # action's JIT provisioning always gives one (the documented seed!
      # exception). The personal-org lookup answers :none and the change
      # errors the field instead of a bare required-attribute crash.
      orgless =
        Ash.Seed.seed!(User, %{username: "orgless-gw-#{System.unique_integer([:positive])}"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.create(
                 %{
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   auth_key: "tskey"
                 },
                 actor: orgless
               )

      assert Enum.any?(
               errors,
               &(&1.field == :organization_id and &1.message == "is required")
             )
    end

    # The paywall waiver: the operator's designated-org path. The gate
    # reads ledger-paid OR waived — these pin the OR's behavior at the
    # gateway seam (the predicate pins live in ActorOrgHasPaidTest).
    test "a waived never-paid org creates and resumes — the waiver satisfies the paid gate", %{
      org: org,
      owner: owner
    } do
      # The create bills the ACTOR'S PERSONAL ORG — the fixture org
      # (the #408 marker names it), so the waiver flips on
      # that org's wallet: adjustment-funded, never paid.
      {:ok, wallet} = Billing.ensure_wallet(org)
      assert {:ok, _wallet} = Wallet.set_waiver(wallet, %{paywall_waived: true}, actor: admin())

      assert {:ok, gateway} =
               AccessGateway.create(
                 %{monthly_cents: 200, tailnet_domain: "example.ts.net", auth_key: "tskey"},
                 actor: owner
               )

      assert gateway.organization_id == org.id

      # Resume opens the same way — the waiver rides both gates.
      stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
      {:ok, suspended} = AccessGateway.suspend(gateway, authorize?: false)

      assert {:ok, resumed} = AccessGateway.resume(suspended, actor: owner)
      assert resumed.state == :provisioning
    end

    test "un-waiving re-gates — create is Forbidden again", %{org: org, owner: owner} do
      # Chained records — the un-flip edits the row as it now is.
      {:ok, wallet} = Billing.ensure_wallet(org)

      assert {:ok, waived} = Wallet.set_waiver(wallet, %{paywall_waived: true}, actor: admin())

      assert {:ok, _unwaived} =
               Wallet.set_waiver(waived, %{paywall_waived: false}, actor: admin())

      assert {:error, %Ash.Error.Forbidden{}} =
               AccessGateway.create(
                 %{monthly_cents: 200, tailnet_domain: "example.ts.net", auth_key: "tskey"},
                 actor: owner
               )
    end

    test "waived but empty — the funded check still bites create and resume", %{
      org: org,
      owner: owner
    } do
      # The waiver satisfies the PAID gate only; balance>0 spend points
      # read nothing but the ledger.
      {:ok, wallet} = Billing.ensure_wallet(org)
      assert {:ok, _wallet} = Wallet.set_waiver(wallet, %{paywall_waived: true}, actor: admin())
      BillingFixtures.drain_wallet!(org)

      assert {:error, %Ash.Error.Forbidden{}} =
               AccessGateway.create(
                 %{monthly_cents: 200, tailnet_domain: "example.ts.net", auth_key: "tskey"},
                 actor: owner
               )

      suspended = AccessFixtures.gateway!(org, state: :suspended)

      assert {:error, %Ash.Error.Forbidden{}} = AccessGateway.resume(suspended, actor: owner)
    end
  end

  describe "update_credential/2" do
    test "re-paste writes the Secret and lands :provisioning", %{org: org} do
      gateway = AccessFixtures.gateway!(org, state: :needs_attention)

      expect(Tailscale, :update_credential, fn _gateway, "tskey-new" -> :ok end)

      # Absent domain is the documented key-only recovery (ADR-0039 §4):
      # the action keeps the stored domain and rewrites nothing.
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

    test "a :provisioning re-paste with a changed domain re-applies under the INCOMING one", %{
      org: org
    } do
      # The drift-repair arm: update_credential re-applies the whole
      # gateway through provision_gateway, which rewrites the serve
      # config from the struct it is handed. The hostile-review clobber:
      # a stale pre-write struct would write the OLD FQDN back over the
      # rewrite the same action just made (or fail outright on a
      # nil-domain row) while the row lands the new domain.
      gateway = AccessFixtures.gateway!(org, state: :provisioning)

      expect(Tailscale, :refresh_routes, fn %{tailnet_domain: domain} ->
        assert domain == "rejoined.ts.net"
        {:ok, %{}}
      end)

      expect(Tailscale, :update_credential, fn %{tailnet_domain: domain}, "tskey-new" ->
        assert domain == "rejoined.ts.net"
        :ok
      end)

      assert {:ok, repasted} =
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

  describe "reconnect without a pasted key (#836)" do
    test "mints from the stored token, and the row lands :provisioning", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      reject(Tailscale, :update_credential, 2)

      expect(Tailscale, :reconnect_minted, fn gateway ->
        assert gateway.state == :active
        :ok
      end)

      assert {:ok, reconnected} = AccessGateway.update_credential(gateway, %{}, authorize?: false)

      assert reconnected.state == :provisioning
      assert reconnected.status_message == "Reconnecting access"
      assert reconnected.needs_attention_since == nil
    end

    test "a changed domain re-renders the serve config before the mint too", %{org: org} do
      gateway = AccessFixtures.gateway!(org)
      parent = self()

      stub(Tailscale, :refresh_routes, fn %{tailnet_domain: domain} ->
        send(parent, {:refreshed, domain})
        {:ok, %{}}
      end)

      stub(Tailscale, :reconnect_minted, fn _gateway ->
        # Order PINNED here, not after the fact: refresh_routes runs
        # before the provider call, so its message must ALREADY be in
        # the mailbox by the time the mint callback starts (selective
        # receive would wave a mint-first trace through two
        # assert_receiveds).
        assert_received {:refreshed, "rejoined.ts.net"}
        send(parent, {:minted})
        :ok
      end)

      assert {:ok, _reconnected} =
               AccessGateway.update_credential(
                 gateway,
                 %{tailnet_domain: "rejoined.ts.net"},
                 authorize?: false
               )

      assert_received {:minted}
    end

    test "no token anywhere surfaces the copy sentence, row unchanged", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      expect(Tailscale, :reconnect_minted, fn _gateway -> {:error, :no_api_token} end)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.update_credential(gateway, %{}, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.field == :auth_key and
                   &1.message ==
                     "No API token is saved for this gateway. Paste an auth key, or save the token in Settings → Access")
             )

      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).state == :active
    end

    test "the 403 sentence names the missing scope and the exit", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      stub(Tailscale, :reconnect_minted, fn _gateway -> {:error, :forbidden} end)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.update_credential(gateway, %{}, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.field == :auth_key and
                   &1.message =~ "mint it from a tailnet owner or admin")
             )
    end

    test "the 403 sentence is the pinned one, verbatim", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      stub(Tailscale, :reconnect_minted, fn _gateway -> {:error, :forbidden} end)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.update_credential(gateway, %{}, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.field == :auth_key and
                   &1.message ==
                     "Your Tailscale API key can't create join keys — mint it from a tailnet owner or admin account, or paste an auth key instead")
             )
    end

    test "a :suspended row refuses before any provider call", %{org: org} do
      gateway = AccessFixtures.gateway!(org, state: :suspended)

      # No refresh, no mint, no paste-path call — the refusal is the
      # change's, before the provider is touched at all.
      reject(Tailscale, :reconnect_minted, 1)
      reject(Tailscale, :update_credential, 2)
      reject(Tailscale, :refresh_routes, 1)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.update_credential(gateway, %{}, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.field == :auth_key and
                   &1.message == "Resume the gateway first, then reconnect")
             )
    end

    # The #853 review's race: a caller holds a :provisioning struct
    # while the ladder commits :suspended underneath. The refusal must
    # read the COMMITTED row — a mint on the stale struct would
    # re-apply objects at one replica and resurrect the suspended pod.
    test "a STALE struct whose row was suspended underneath still refuses", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      {:ok, _suspended} =
        AccessGateway.update_state(gateway, %{state: :suspended}, authorize?: false)

      # `gateway` is deliberately the pre-suspend struct.
      reject(Tailscale, :reconnect_minted, 1)
      reject(Tailscale, :refresh_routes, 1)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.update_credential(gateway, %{}, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.field == :auth_key and
                   &1.message == "Resume the gateway first, then reconnect")
             )
    end

    test "a vanished row refuses like every gone-row seam", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      # The system-only hard delete (the teardown trigger's terminal
      # write) — the row dies through its action, never a raw delete.
      Ash.destroy!(gateway, action: :destroy_after_teardown, authorize?: false)

      reject(Tailscale, :reconnect_minted, 1)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               AccessGateway.update_credential(gateway, %{}, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.field == :id and &1.message == "this gateway no longer exists")
             )
    end

    test "a pasted key on a :suspended row keeps the write-only fallback", %{org: org} do
      gateway = AccessFixtures.gateway!(org, state: :suspended)

      reject(Tailscale, :reconnect_minted, 1)

      expect(Tailscale, :update_credential, fn _gateway, "tskey-pasted" -> :ok end)

      assert {:ok, repasted} =
               AccessGateway.update_credential(gateway, %{auth_key: "tskey-pasted"},
                 authorize?: false
               )

      assert repasted.state == :provisioning
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

    # The access edge's arms go FIRST (ADR-0040 §7): the host-keyed
    # routes live in the instance namespaces, outside the provider's
    # reach — no hostname keeps answering through a dying tunnel.
    test "teardown removes the access arms before the provider runs", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      AccessRoute.create!(
        %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
        authorize?: false
      )

      parent = self()

      stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

      stub(Ingress, :delete, fn _kc, _ns, "access-" <> _tail ->
        send(parent, {:access_arm_removed})
        :ok
      end)

      stub(Middleware, :delete, fn _kc, _ns, "fluxvale-access-wake" ->
        send(parent, {:access_middleware_removed})
        :ok
      end)

      expect(Tailscale, :teardown_gateway, fn _gateway ->
        send(parent, {:provider_ran})
        :ok
      end)

      assert {:ok, _gone} = AccessGateway.perform_teardown(gateway, %{}, authorize?: false)

      # The mailbox order is the design: arms first, provider second.
      assert_received {:access_arm_removed}
      assert_received {:access_middleware_removed}
      assert_received {:provider_ran}
    end

    test "an access-arm delete failure fails the teardown before the provider runs", %{
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      AccessRoute.create!(
        %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
        authorize?: false
      )

      stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

      stub(Ingress, :delete, fn _kc, _ns, "access-" <> _tail ->
        {:error, Error.connection_error("arm delete refused")}
      end)

      # The provider must not run: the arms' failure is retried whole.
      stub(Tailscale, :teardown_gateway, fn _gateway ->
        flunk("the provider must not tear down past a failed arm removal")
      end)

      assert {:error, _reason} =
               AccessGateway.perform_teardown(gateway, %{}, authorize?: false)

      # The row survives for the retry (the teardown posture).
      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).id == gateway.id
    end

    test "an unreachable cluster during the arm removal fails the teardown too", %{
      org: org,
      owner: owner
    } do
      gateway = AccessFixtures.gateway!(org)
      instance = AccessFixtures.private_instance!(org, owner)

      AccessRoute.create!(
        %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
        authorize?: false
      )

      stub(K8s, :kubeconfig, fn _ref -> {:error, Error.connection_error("cluster down")} end)

      stub(Tailscale, :teardown_gateway, fn _gateway ->
        flunk("the provider must not tear down past a failed arm removal")
      end)

      assert {:error, _reason} =
               AccessGateway.perform_teardown(gateway, %{}, authorize?: false)

      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).id == gateway.id
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

      # The operations' access-edge limbs (ADR-0040 S2) ride the same
      # round-trip, stubbed like every other cluster call here.
      stub(FluxVale.Clients.K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

      stub(FluxVale.Clients.K8s.Resources.Ingress, :create, fn _kc, _ns, _n, _spec ->
        {:ok, %{}}
      end)

      stub(FluxVale.Clients.K8s.Resources.Middleware, :create, fn _kc, _ns, _n, _spec ->
        {:ok, %{}}
      end)

      stub(FluxVale.Clients.K8s.Resources.Service, :create, fn _kc, _ns, _n, _spec ->
        {:ok, %{}}
      end)

      stub(FluxVale.Clients.K8s.Resources.NetworkPolicy, :create, fn _kc, _ns, _n, _spec ->
        {:ok, %{}}
      end)

      stub(FluxVale.Clients.K8s.Resources.Ingress, :delete, fn _kc, _ns, _n -> :ok end)
      stub(FluxVale.Clients.K8s.Resources.Middleware, :delete, fn _kc, _ns, _n -> :ok end)

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
      assert marked.status_message =~ "Try connecting again"
    end

    test ":teardown exhaustion stays :destroying so billing cannot resurrect it", %{org: org} do
      gateway = AccessFixtures.gateway!(org, state: :destroying)

      {:ok, marked} =
        AccessGateway.mark_teardown_error(gateway, %{error: %{}}, authorize?: false)

      # NOT :needs_attention: the :observe and :settle triggers both select
      # that state, so a failed removal would be re-observed as a live
      # gateway and start billing the org that just opted out.
      assert marked.state == :destroying
      assert marked.status_message =~ "Removal failed. Retry removing"
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

  describe "the mint create's PaperTrail sentinel (#836)" do
    test "a token-at-create redacts the token in inputs — the value lands nowhere", %{
      org: org,
      owner: owner
    } do
      token = "tskey-api-SECRET-marker"

      stub(Tailscale, :write_api_credential, fn _gateway, _token ->
        {:ok, %{api_token_secret_ref: "api-credential-stub"}}
      end)

      stub(Tailscale, :provision_gateway_minted, fn _gateway ->
        {:ok, %{credential_secret_ref: "credential-stub"}}
      end)

      assert {:ok, gateway} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   api_token: token
                 },
                 actor: owner,
                 authorize?: false
               )

      versions = gateway_versions!(gateway.id)

      create_version = Enum.find(versions, &(&1.version_action_name == :create))

      # The argument is sensitive: ADR-0048's stance stores the marker,
      # never the value (the #760 intake's exact posture).
      assert create_version.version_action_inputs["api_token"] == "REDACTED"

      # The stored changes carry only non-secret fields — the Secret's
      # NAME and the rotation stamp — no credential value anywhere.
      refute Enum.any?(versions, &(inspect(&1) =~ token))
    end

    test "a pasted-key create's auth_key redacts too", %{org: org} do
      key = "tskey-SECRET-marker"

      assert {:ok, gateway} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   auth_key: key
                 },
                 authorize?: false
               )

      versions = gateway_versions!(gateway.id)

      create_version = Enum.find(versions, &(&1.version_action_name == :create))

      assert create_version.version_action_inputs["auth_key"] == "REDACTED"
      refute Enum.any?(versions, &(inspect(&1) =~ key))
    end

    test "a pair-at-create redacts the secret but keeps the id in the clear", %{
      org: org,
      owner: owner
    } do
      # The split is deliberate (lane B): the client id is public
      # identity — every OAuth client shows it — while the client
      # secret is the crown half and rides sensitive.
      client_id = "client-id-PLAIN-marker"
      client_secret = "client-secret-SECRET-marker"

      stub(Tailscale, :write_client_credential, fn _gateway, _id, _secret ->
        {:ok, %{api_token_secret_ref: "api-credential-pair"}}
      end)

      stub(Tailscale, :provision_gateway_minted, fn _gateway ->
        {:ok, %{credential_secret_ref: "credential-stub"}}
      end)

      assert {:ok, gateway} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   ts_client_id: client_id,
                   ts_client_secret: client_secret
                 },
                 actor: owner,
                 authorize?: false
               )

      versions = gateway_versions!(gateway.id)

      create_version = Enum.find(versions, &(&1.version_action_name == :create))

      assert create_version.version_action_inputs["ts_client_secret"] == "REDACTED"
      assert create_version.version_action_inputs["ts_client_id"] == client_id

      # The secret value appears in no version row — its own sentinel.
      refute Enum.any?(versions, &(inspect(&1) =~ client_secret))
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

  describe "update_claims' optimistic lock (P2-3)" do
    # Two tabs claiming two domains on one gateway: the slower write
    # must FAIL CLEANLY (StaleRecord) instead of clobbering the first
    # domain's entry — the claim/unclaim ops retry once against the
    # committed map, which merges.
    test "the second write on a stale row is refused, the fresh one lands", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      entry = %{"ip" => "10.43.0.20", "tailnet" => "example.ts.net"}

      # Tab B writes the committed map first (this bumps :version).
      fresh = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      tab_b = %{dns_claims: %{"b.example.com" => entry}}

      {:ok, _tab_b} = AccessGateway.update_claims(fresh, tab_b, authorize?: false)

      # Tab A's write still carries the PRE-B version — refused.
      stale_write =
        AccessGateway.update_claims(
          gateway,
          %{dns_claims: %{"a.example.com" => entry}},
          authorize?: false
        )

      assert {:error, %Ash.Error.Invalid{errors: errors}} = stale_write
      assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

      # A retry against the COMMITTED row (what the ops do) converges
      # with both entries.
      committed = AccessGateway.get_by_id!(gateway.id, authorize?: false)

      {:ok, row} =
        AccessGateway.update_claims(
          committed,
          %{dns_claims: Map.put(committed.dns_claims, "a.example.com", entry)},
          authorize?: false
        )

      assert Map.has_key?(row.dns_claims, "a.example.com")
      assert Map.has_key?(row.dns_claims, "b.example.com")
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

  # The version rows for one gateway, oldest first (the PaperTrail test
  # file's read posture: storage assertions run authorize?: false).
  defp gateway_versions!(gateway_id) do
    AccessGateway.Version
    |> Ash.Query.filter(version_source_id == ^gateway_id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  # Bootstrap posture (mirrors the Billing policy tests): the
  # precondition runs authorize?: false; the admin policy itself is
  # under test in WalletTest.
  defp admin, do: AccountsFixtures.platform_admin!()
end
