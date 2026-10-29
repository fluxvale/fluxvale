defmodule FluxVale.Checks.ActorOrgWalletFundedTest do
  @moduledoc false

  # #124's gate: an Ash policy check (the API can't walk around it),
  # wired to Instance create + start. A wallet-less org is unfunded —
  # balance 0 by definition. Balances are exact: the billing fixture's
  # orgs skip the JIT path (no welcome grant, #122).

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Checks.ActorOrgWalletFunded
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()
    {:ok, version: version}
  end

  describe "org_funded?/1" do
    test "a positive balance funds the org" do
      {_org, wallet} = BillingFixtures.funded_wallet!()
      assert ActorOrgWalletFunded.org_funded?(wallet.organization_id)
    end

    test "an empty wallet does not fund the org" do
      {_org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)
      refute ActorOrgWalletFunded.org_funded?(wallet.organization_id)
    end

    test "a wallet-less org is unfunded — balance 0 by definition" do
      {org, _owner} = BillingFixtures.grant_free_org!()
      refute ActorOrgWalletFunded.org_funded?(org.id)
    end
  end

  describe "the check itself" do
    test "describe/1 names the gate" do
      assert is_binary(ActorOrgWalletFunded.describe([]))
    end

    test "an actor with no org passes — the create's own org-required validation answers" do
      # Ash.Seed.seed! — the only way to produce an org-less user: the
      # create action's JIT change always provisions one (the documented
      # seed! exception).
      orgless = Ash.Seed.seed!(User, %{email: "orgless-#{System.unique_integer()}@fluxvale.test"})

      create_subject = Ash.Changeset.for_create(Instance, :create, %{}, authorize?: false)

      # create changesets carry no org yet → the actor path → :none → pass
      assert ActorOrgWalletFunded.match?(orgless, %{subject: create_subject}, [])
    end
  end

  describe "the Instance create gate" do
    test "a funded actor creates; a drained one is forbidden", %{version: version} do
      {_org, _wallet, funded_owner} = funded_org_owner!()

      assert {:ok, _instance} =
               Instance.create(
                 %{name: "Funded", app_version_id: version.id, env_vars: %{}},
                 actor: funded_owner
               )

      {_org, _wallet, drained_owner} = funded_org_owner!(balance_cents: 0)

      assert {:error, %Ash.Error.Forbidden{}} =
               Instance.create(
                 %{name: "Drained", app_version_id: version.id, env_vars: %{}},
                 actor: drained_owner
               )
    end

    test "a wallet-less org is not funded — creation is forbidden", %{version: version} do
      {_org, walletless_owner} = BillingFixtures.grant_free_org!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Instance.create(
                 %{name: "NoWallet", app_version_id: version.id, env_vars: %{}},
                 actor: walletless_owner
               )
    end
  end

  describe "the Instance deploy gate" do
    test "deploy/retry is forbidden while the wallet is empty, open after a top-up", %{
      version: version
    } do
      stub_k8s()

      {org, wallet, owner} = funded_org_owner!()

      instance =
        Instance.create!(%{name: "Deploy Gate", app_version_id: version.id, env_vars: %{}},
          actor: owner
        )

      BillingFixtures.drain_wallet!(org)

      assert {:error, %Ash.Error.Forbidden{}} = Instance.deploy(instance, actor: owner)

      {:ok, _grant} = Billing.grant_credits(wallet, 100, reason: :adjustment)
      assert {:ok, deployed} = Instance.deploy(instance, actor: owner)
      assert deployed.namespace == "fluxvale-app-#{instance.id}"
    end
  end

  describe "the Instance start gate" do
    test "start is forbidden while the wallet is empty, open after a top-up", %{
      version: version
    } do
      stub_scale()

      {org, wallet, owner} = funded_org_owner!()

      instance =
        Instance.create!(%{name: "Gate", app_version_id: version.id, env_vars: %{}}, actor: owner)

      stopped =
        Enum.reduce([:deploying, :starting, :running, :stopped], instance, fn status, acc ->
          {:ok, next} = InstanceK8s.update_status(acc, status, nil)
          next
        end)

      InstanceFixtures.pin!(stopped, namespace: "fluxvale-app-#{instance.id}")

      BillingFixtures.drain_wallet!(org)

      assert {:error, %Ash.Error.Forbidden{}} = Instance.start(stopped, actor: owner)

      {:ok, _grant} = Billing.grant_credits(wallet, 100, reason: :adjustment)
      assert {:ok, starting} = Instance.start(stopped, actor: owner)
      assert starting.status == :starting
    end
  end

  # funded_wallet! wraps grant_free_org!: exact balances, no welcome
  # grant in the arithmetic — unwrapped here for the actor triple.
  defp funded_org_owner!(opts \\ []) do
    {org, owner} = BillingFixtures.grant_free_org!()
    {_org, wallet} = BillingFixtures.funded_wallet!([{:org, org} | opts])
    {org, wallet, owner}
  end

  defp stub_scale do
    stub(FluxVale.Clients.K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(FluxVale.Clients.K8s.Resources.Deployment, :scale, fn _kc, _ns, _n, 1 -> {:ok, %{}} end)
  end

  # The deploy action fires its trigger inline in tests — the full K8s
  # create surface stubbed (instance_test's shape).
  defp stub_k8s do
    stub(FluxVale.Clients.K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    stub(FluxVale.Clients.K8s.Resources.Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)

    stub(FluxVale.Clients.K8s.Resources.RoleBinding, :create, fn _kc, _ns, _n, _spec ->
      {:ok, %{}}
    end)

    stub(FluxVale.Clients.K8s.Resources.ResourceQuota, :create, fn _kc, _ns, _n, _spec ->
      {:ok, %{}}
    end)

    stub(FluxVale.Clients.K8s.Resources.NetworkPolicy, :create, fn _kc, _ns, _n, _spec ->
      {:ok, %{}}
    end)

    stub(FluxVale.Clients.K8s.Resources.PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec ->
      {:ok, %{}}
    end)

    stub(FluxVale.Clients.K8s.Resources.Secret, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

    stub(FluxVale.Clients.K8s.Resources.Deployment, :create, fn _kc, _ns, _n, _spec ->
      {:ok, %{}}
    end)

    stub(FluxVale.Clients.K8s.Resources.Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

    stub(FluxVale.Clients.K8s.Resources.Ingress, :create, fn _kc, _ns, _n, _spec ->
      {:ok, %{}}
    end)
  end
end
