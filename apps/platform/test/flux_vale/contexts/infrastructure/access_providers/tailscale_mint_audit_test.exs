defmodule FluxVale.Infrastructure.AccessProviders.TailscaleMintAuditTest do
  @moduledoc """
  The mint audit line's custody pin (R3): the happy path's `Logger.info`
  carries the key ID and never the value.

  A sync module on purpose: the `:info` line sits below the test env's
  `:warning` level, and capturing it from the async provider suite would
  mean mutating the global Logger level beside concurrently running
  tests — the undetermined behavior ExUnit's own docs warn about. Sync
  modules run alone, so the capture's level lift cannot bleed.
  """

  # async: false — the capture raises the Logger level for its duration
  # (see the moduledoc).
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessProviders.Tailscale.ApiClient
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  @api_token "tskey-api-audit"
  @key_id "kaudit1"
  @secret_suffix "auditsecretvalue"

  setup do
    parent = self()

    InstanceFixtures.local_cluster!()

    stub(FluxVale.Clients.K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    stub(FluxVale.Clients.K8s.Resources.Secret, :get_data, fn _kc, _ns, _name ->
      {:ok, %{"TS_API_TOKEN" => @api_token}}
    end)

    stub(ApiClient, :keys_create, fn token, _opts ->
      send(parent, {:keys_create, token})
      {:ok, %{id: @key_id, key: "tskey-auth-#{@key_id}-#{@secret_suffix}"}}
    end)

    stub(ApiClient, :keys_delete, fn _token, _key_id -> :ok end)

    stub(FluxVale.Clients.K8s.Resources.Secret, :create, fn _kc, _ns, _name, _data ->
      {:ok, %{}}
    end)

    stub(FluxVale.Clients.K8s.Resources.PersistentVolumeClaim, :create, fn _kc, _ns, _n, _s ->
      {:ok, %{}}
    end)

    stub(FluxVale.Clients.K8s.Resources.Deployment, :apply_manifest, fn _kc, _manifest ->
      {:ok, %{}}
    end)

    {org, _owner} = BillingFixtures.grant_free_org!()

    gateway =
      AccessGateway.create!(
        %{
          organization_id: org.id,
          monthly_cents: 200,
          tailnet_domain: "example.ts.net",
          auth_key: "tskey"
        },
        authorize?: false
      )

    {:ok, gateway: gateway, parent: parent}
  end

  test "the mint audit line carries the id, never the value", %{
    gateway: gateway,
    parent: parent
  } do
    # The primary level (test config: :warning) filters :info before any
    # handler can see it, so the capture needs the primary level raised.
    # Safe only because this module is sync (async: false) — the level
    # cannot bleed into a concurrently running test.
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{credential_secret_ref: _ref}} =
                 Tailscale.provision_gateway_minted(gateway)
      end)

    assert log =~ "minted enrollment key #{@key_id}"
    refute log =~ @secret_suffix
    assert_received {:keys_create, @api_token}
  end
end
