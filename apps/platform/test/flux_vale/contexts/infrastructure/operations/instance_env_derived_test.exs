defmodule FluxVale.Infrastructure.Operations.InstanceEnvDerivedTest do
  @moduledoc false

  # #731: the shared allowlist append — one owner for the deploy and the
  # in-place patch. Idempotent: a value already carrying a host keeps
  # the user's string exactly.
  #
  # The custom-address slice: `derive/1` (and its one-shot wrappers)
  # read the live hostnames (the same claimed-domain gates the default
  # predicate rides, extended to custom rows), oldest custom first.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.Infrastructure.Operations.InstanceEnvDerived
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    verify_on_exit!()

    stub(Kubereq, :attach, fn req, _opts -> req end)

    stub(Kubereq, :apply, fn _req, manifest, _fm ->
      {:ok, %{status: 201, body: manifest}}
    end)

    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    :ok
  end

  defp host(slug) do
    "#{slug}.#{Application.fetch_env!(:flux_vale, :instances_base_domain)}"
  end

  defp version, do: %{host_allowlist_env: "ALLOWED_HOSTS"}

  test "a nil host list becomes the platform host" do
    assert InstanceEnvDerived.allowlist_entry(%{}, [host("app")], version()) == %{
             "ALLOWED_HOSTS" => host("app")
           }
  end

  test "multiple hosts get the platform host appended once" do
    assert InstanceEnvDerived.allowlist_entry(
             %{"ALLOWED_HOSTS" => "localhost,127.0.0.1"},
             [host("app")],
             version()
           ) == %{"ALLOWED_HOSTS" => "localhost,127.0.0.1,#{host("app")}"}
  end

  test "an empty value becomes the platform host" do
    assert InstanceEnvDerived.allowlist_entry(
             %{"ALLOWED_HOSTS" => ""},
             [host("app")],
             version()
           ) == %{"ALLOWED_HOSTS" => host("app")}
  end

  test "a value already containing the platform host is preserved exactly" do
    existing = "localhost, #{host("app")}"

    assert InstanceEnvDerived.allowlist_entry(
             %{"ALLOWED_HOSTS" => existing},
             [host("app")],
             version()
           ) == %{"ALLOWED_HOSTS" => existing}
  end

  test "a value already containing a custom host is preserved exactly" do
    custom = "git.apps-1.customer.test"
    existing = "localhost,#{custom}"

    assert InstanceEnvDerived.allowlist_entry(
             %{"ALLOWED_HOSTS" => existing},
             [custom],
             version()
           ) == %{"ALLOWED_HOSTS" => existing}
  end

  test "a nil host_allowlist_env leaves the map untouched" do
    env = %{"KEEP" => "1"}

    assert InstanceEnvDerived.allowlist_entry(env, [host("app")], %{host_allowlist_env: nil}) ==
             env
  end

  test "no hostnames leaves the env untouched" do
    env = %{"ALLOWED_HOSTS" => "localhost"}

    assert InstanceEnvDerived.allowlist_entry(env, [], version()) == env
  end

  describe "instance_url/1" do
    test "a public instance answers on its default hostname" do
      {_org, row} = org_instance!(:public)

      assert InstanceEnvDerived.instance_url(row) == "https://#{host(row.slug)}/"
    end

    test "a public instance ignores a recorded custom row" do
      {org, row} = org_instance!(:public)
      domain = AccessFixtures.verified_domain!(org)
      AccessFixtures.mint_hostname!(row, domain, "git")

      assert InstanceEnvDerived.instance_url(row) == "https://#{host(row.slug)}/"
    end

    test "a private unattached instance has no URL" do
      {_org, row} = org_instance!(:private)

      assert InstanceEnvDerived.instance_url(row) == nil
    end

    test "a private attached instance with nothing live has no URL" do
      {org, row} = org_instance!(:private)
      attach!(org, row)

      assert InstanceEnvDerived.instance_url(row) == nil
    end

    test "a claimed base domain makes the default hostname the URL" do
      {org, row} = org_instance!(:private)
      gateway = attach!(org, row)
      AccessFixtures.claim!(gateway, [base_domain()])

      assert InstanceEnvDerived.instance_url(row) == "https://#{host(row.slug)}/"
    end

    test "a live custom address answers when the default hostname is dark" do
      {org, row} = org_instance!(:private)
      gateway = attach!(org, row)
      domain = AccessFixtures.verified_domain!(org)
      AccessFixtures.claim!(gateway, [domain.domain])
      AccessFixtures.mint_hostname!(row, domain, "git")

      assert InstanceEnvDerived.instance_url(row) == "https://git.#{domain.domain}/"
    end

    test "a live custom beats the live default" do
      {org, row} = org_instance!(:private)
      gateway = attach!(org, row)
      domain = AccessFixtures.verified_domain!(org)
      AccessFixtures.claim!(gateway, [base_domain(), domain.domain])
      AccessFixtures.mint_hostname!(row, domain, "git")

      assert InstanceEnvDerived.instance_url(row) == "https://git.#{domain.domain}/"
    end

    test "the OLDEST live custom wins" do
      {org, row} = org_instance!(:private)
      gateway = attach!(org, row)
      domain = AccessFixtures.verified_domain!(org)
      AccessFixtures.claim!(gateway, [domain.domain])
      AccessFixtures.mint_hostname!(row, domain, "git")
      AccessFixtures.mint_hostname!(row, domain, "code")

      assert InstanceEnvDerived.instance_url(row) == "https://git.#{domain.domain}/"
    end

    test "the OLDEST live custom wins across a month boundary (chronological, not term order)" do
      {org, row} = org_instance!(:private)
      gateway = attach!(org, row)
      domain = AccessFixtures.verified_domain!(org)
      AccessFixtures.claim!(gateway, [domain.domain])

      # actions cannot produce a backdated created_at
      _older =
        Ash.Seed.seed!(InstanceHostname, %{
          instance_id: row.id,
          access_domain_id: domain.id,
          label: "git",
          created_at: ~U[2026-11-30 12:00:00Z]
        })

      # actions cannot produce a backdated created_at
      _newer =
        Ash.Seed.seed!(InstanceHostname, %{
          instance_id: row.id,
          access_domain_id: domain.id,
          label: "code",
          created_at: ~U[2026-12-01 12:00:00Z]
        })

      # DateTime term order ranks 2026-11-30 AFTER 2026-12-01 — only the
      # chronological sort keeps "git" the oldest.
      assert InstanceEnvDerived.instance_url(row) == "https://git.#{domain.domain}/"
    end

    test "a needs_attention custom domain is live" do
      {org, row} = org_instance!(:private)
      gateway = attach!(org, row)
      domain = AccessFixtures.needs_attention_domain!(org)
      AccessFixtures.claim!(gateway, [domain.domain])
      AccessFixtures.mint_hostname!(row, domain, "git")

      assert InstanceEnvDerived.instance_url(row) == "https://git.#{domain.domain}/"
    end

    test "a claimed custom domain still pending is not live" do
      {org, row} = org_instance!(:private)
      gateway = attach!(org, row)
      domain = AccessFixtures.custom_domain!(org)
      AccessFixtures.claim!(gateway, [domain.domain])
      AccessFixtures.mint_hostname!(row, domain, "git")

      assert InstanceEnvDerived.instance_url(row) == nil
    end

    test "a claim whose hostname row is gone is not live" do
      {org, row} = org_instance!(:private)
      gateway = attach!(org, row)
      domain = AccessFixtures.verified_domain!(org)
      AccessFixtures.claim!(gateway, [domain.domain])
      hostname = AccessFixtures.mint_hostname!(row, domain, "git")
      InstanceHostname.destroy(hostname, authorize?: false)

      assert InstanceEnvDerived.instance_url(row) == nil
    end

    test "a hostname row pointing at another org's domain is not live (the org fence)" do
      {org_a, row} = org_instance!(:private)
      gateway = attach!(org_a, row)
      domain_a = AccessFixtures.verified_domain!(org_a)
      {org_b, _owner_b} = BillingFixtures.grant_free_org!()
      domain_b = AccessFixtures.verified_domain!(org_b)

      # the drift the fence exists for: A's gateway answering for BOTH
      # its own name and org B's domain name (the observed-state write
      # the platform never makes on its own)
      AccessFixtures.claim!(gateway, [domain_a.domain, domain_b.domain])

      # actions cannot produce a cross-org row (the mint guard
      # refuses); the fence's regression pin
      _seeded =
        Ash.Seed.seed!(InstanceHostname, %{
          instance_id: row.id,
          access_domain_id: domain_b.id,
          label: "git",
          created_at: DateTime.utc_now()
        })

      assert InstanceEnvDerived.instance_url(row) == nil
    end
  end

  describe "serving_hostnames/1" do
    test "a public instance serves the default hostname" do
      {_org, row} = org_instance!(:public)

      assert InstanceEnvDerived.serving_hostnames(row) == [host(row.slug)]
    end

    test "a private unattached instance serves nothing" do
      {_org, row} = org_instance!(:private)

      assert InstanceEnvDerived.serving_hostnames(row) == []
    end

    test "a private attached instance with nothing live serves nothing" do
      {org, row} = org_instance!(:private)
      attach!(org, row)

      assert InstanceEnvDerived.serving_hostnames(row) == []
    end

    test "a live custom serves without the dark default" do
      {org, row} = org_instance!(:private)
      gateway = attach!(org, row)
      domain = AccessFixtures.verified_domain!(org)
      AccessFixtures.claim!(gateway, [domain.domain])
      AccessFixtures.mint_hostname!(row, domain, "git")

      assert InstanceEnvDerived.serving_hostnames(row) == ["git.#{domain.domain}"]
    end

    test "the live default serves first, the live custom rides along" do
      {org, row} = org_instance!(:private)
      gateway = attach!(org, row)
      domain = AccessFixtures.verified_domain!(org)
      AccessFixtures.claim!(gateway, [base_domain(), domain.domain])
      AccessFixtures.mint_hostname!(row, domain, "git")

      assert InstanceEnvDerived.serving_hostnames(row) == [
               host(row.slug),
               "git.#{domain.domain}"
             ]
    end

    test "two live customs serve in mint order" do
      {org, row} = org_instance!(:private)
      gateway = attach!(org, row)
      domain = AccessFixtures.verified_domain!(org)
      AccessFixtures.claim!(gateway, [domain.domain])
      AccessFixtures.mint_hostname!(row, domain, "git")
      AccessFixtures.mint_hostname!(row, domain, "code")

      assert InstanceEnvDerived.serving_hostnames(row) == [
               "git.#{domain.domain}",
               "code.#{domain.domain}"
             ]
    end
  end

  describe "derive/1 — one snapshot" do
    test "the URL and the hostnames come from the same reads" do
      {org, row} = org_instance!(:private)
      gateway = attach!(org, row)
      domain = AccessFixtures.verified_domain!(org)
      AccessFixtures.claim!(gateway, [base_domain(), domain.domain])
      AccessFixtures.mint_hostname!(row, domain, "git")

      assert InstanceEnvDerived.derive(row) == %{
               url: "https://git.#{domain.domain}/",
               hostnames: [host(row.slug), "git.#{domain.domain}"]
             }
    end

    test "a dark private row snapshots nil and no hostnames" do
      {_org, row} = org_instance!(:private)

      assert InstanceEnvDerived.derive(row) == %{url: nil, hostnames: []}
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp base_domain, do: Application.fetch_env!(:flux_vale, :instances_base_domain)

  # The fixture org IS the actor's personal org (the #408 marker), so
  # the create lands the row in the gateway's org — and mints its
  # default hostname (and the born-:verified platform domain) with it.
  defp org_instance!(exposure) do
    {org, owner} = BillingFixtures.grant_free_org!()
    {^org, _wallet} = BillingFixtures.funded_wallet!(org: org)
    InstanceFixtures.local_cluster!()

    version = InstanceFixtures.app_version!()

    row =
      Instance.create!(
        %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: owner
      )

    {org, InstanceFixtures.pin!(row, exposure: exposure)}
  end

  defp attach!(org, row) do
    gateway = AccessFixtures.gateway!(org)

    AccessRoute.create!(
      %{gateway_id: gateway.id, instance_id: row.id, route_key: "8443"},
      authorize?: false
    )

    gateway
  end
end
