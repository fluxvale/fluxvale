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
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.AccountsFixtures
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

    test "a reload failure fails closed — a struct naming no row never passes" do
      {_org, wallet} = BillingFixtures.funded_wallet!()

      # The in-memory struct CLAIMS the funded org, but its primary key
      # names no row: the fresh DB read fails and the gate answers
      # false instead of trusting the caller.
      phantom = %Instance{id: Ecto.UUID.generate(), organization_id: wallet.organization_id}
      changeset = Ash.Changeset.for_update(phantom, :start, %{}, authorize?: false)

      refute ActorOrgWalletFunded.match?(nil, %{subject: changeset}, [])
    end

    test "a non-changeset subject fails closed — even for a funded actor" do
      # The old create-stance catch-all routed queries/action-inputs to
      # the actor path: a funded actor answered true on an arbitrary
      # subject. Fail closed.
      funded_actor = AccountsFixtures.user!()
      AccountsFixtures.personal_org!(funded_actor)

      refute ActorOrgWalletFunded.match?(funded_actor, %{subject: %Instance{}}, [])
    end

    test "an atomic changeset's placeholder data fails closed without raising" do
      # Ash.reload raises on Ash.Changeset.OriginalDataNotAvailable —
      # the clause before the generic data arm answers :error instead.
      {_org, wallet} = BillingFixtures.funded_wallet!()

      changeset =
        Ash.Changeset.for_update(
          %Instance{id: Ecto.UUID.generate(), organization_id: wallet.organization_id},
          :start,
          %{},
          authorize?: false
        )

      atomic = %{changeset | data: %Ash.Changeset.OriginalDataNotAvailable{}}

      refute ActorOrgWalletFunded.match?(nil, %{subject: atomic}, [])
    end

    test "a settings row's org resolves THROUGH its instance — the ROW org's wallet answers, not the actor's",
         %{
           version: version
         } do
      # The BackupSetting shape: the row belongs to its instance, not
      # the organization, so the check reads the org one hop along the
      # same FK the policies read — the ROW org, never the actor's.
      owner =
        User.create!("funded-through-#{System.unique_integer()}@fluxvale.test", %{},
          authorize?: false
        )

      paid_actor =
        User.create!("funded-through-actor-#{System.unique_integer()}@fluxvale.test", %{},
          authorize?: false
        )

      BillingFixtures.mark_user_paid!(paid_actor)

      instance =
        Instance.create!(
          %{name: "Through", app_version_id: version.id, env_vars: %{}},
          actor: owner
        )

      setting =
        BackupSetting
        |> Ash.Changeset.for_create(
          :create,
          %{
            instance_id: instance.id,
            endpoint: "https://account.r2.cloudflarestorage.com",
            bucket: "fluxvale-kavita",
            access_key_id: "AKIAIOSFODNN7EXAMPLE"
          },
          authorize?: false
        )
        |> Ash.create!()

      # The row org drains AFTER its instance existed: if the actor path
      # answered, the PAID actor would pass. The row org is what answers.
      row_org = AccountsFixtures.personal_org!(owner)
      BillingFixtures.drain_wallet!(row_org)

      changeset = Ash.Changeset.for_update(setting, :update, %{}, authorize?: false)

      refute ActorOrgWalletFunded.match?(paid_actor, %{subject: changeset}, [])
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

    test "a forged struct naming a funded org is still refused — the row's org answers", %{
      version: version
    } do
      # An in-process caller controls the changeset's in-memory struct:
      # forge its organization_id to name the actor's FUNDED personal
      # org while the real row's org is drained. The check re-reads the
      # row from the DB, so the forgery changes nothing.
      stub_scale()

      {org, _wallet, owner} = funded_org_owner!()

      instance =
        Instance.create!(%{name: "Forge", app_version_id: version.id, env_vars: %{}},
          actor: owner
        )

      stopped =
        Enum.reduce([:deploying, :starting, :running, :stopped], instance, fn status, acc ->
          {:ok, next} = InstanceK8s.update_status(acc, status, nil)
          next
        end)

      InstanceFixtures.pin!(stopped, namespace: "fluxvale-app-#{instance.id}")

      BillingFixtures.drain_wallet!(org)

      # A second org the actor owns, funded — the forgery's claim.
      funded_other = AccountsFixtures.owned_org!(owner)
      BillingFixtures.funded_wallet!(org: funded_other)

      changeset = Ash.Changeset.for_update(stopped, :start, %{}, actor: owner)
      forged = %{changeset | data: %{stopped | organization_id: funded_other.id}}

      assert {:error, %Ash.Error.Forbidden{}} = Instance.start(forged, actor: owner)
    end

    test "a create naming its instance answers the INSTANCE org, not the actor's — both directions",
         %{version: version} do
      # The team-org hazard, funded edition: the row's org is the
      # INSTANCE's org. A funded member of a drained org's instance is
      # refused, a drained member of a funded org's instance passes —
      # the row org answers, whichever way the wallets point.
      funded_member =
        User.create!("create-wallet-funded-#{System.unique_integer()}@fluxvale.test", %{},
          authorize?: false
        )

      drained_member =
        User.create!("create-wallet-drained-#{System.unique_integer()}@fluxvale.test", %{},
          authorize?: false
        )

      funded_org = AccountsFixtures.personal_org!(funded_member)
      drained_org = AccountsFixtures.personal_org!(drained_member)

      # Welcome-funded at create; drained after (exact ledger shapes).
      theirs =
        Instance.create!(
          %{name: "Drained Org's", app_version_id: version.id, env_vars: %{}},
          actor: drained_member
        )

      ours =
        Instance.create!(
          %{name: "Funded Org's", app_version_id: version.id, env_vars: %{}},
          actor: funded_member
        )

      BillingFixtures.drain_wallet!(drained_org)

      unpaid_orgs_instance =
        Ash.Changeset.for_create(
          BackupSetting,
          :create,
          %{
            instance_id: theirs.id,
            endpoint: "https://s3.example.com",
            bucket: "some-bucket",
            access_key_id: "KEY"
          },
          authorize?: false
        )

      funded_orgs_instance =
        Ash.Changeset.for_create(
          BackupSetting,
          :create,
          %{
            instance_id: ours.id,
            endpoint: "https://s3.example.com",
            bucket: "some-bucket",
            access_key_id: "KEY"
          },
          authorize?: false
        )

      refute ActorOrgWalletFunded.org_funded?(drained_org.id)
      assert ActorOrgWalletFunded.org_funded?(funded_org.id)

      # The FUNDED member against the drained org's instance: refused.
      refute ActorOrgWalletFunded.match?(funded_member, %{subject: unpaid_orgs_instance}, [])

      # The DRAINED member against the funded org's instance: passes.
      assert ActorOrgWalletFunded.match?(drained_member, %{subject: funded_orgs_instance}, [])
    end

    test "a create naming an instance that cannot resolve fails closed" do
      # The create arm's discipline: the instance org answers, and an
      # instance that cannot resolve (a phantom id) is :error — never
      # the actor path, even for a funded actor.
      funded_actor = AccountsFixtures.user!()
      AccountsFixtures.personal_org!(funded_actor)

      changeset =
        Ash.Changeset.for_create(
          BackupSetting,
          :create,
          %{
            instance_id: Ecto.UUID.generate(),
            endpoint: "https://s3.example.com",
            bucket: "some-bucket",
            access_key_id: "KEY"
          },
          authorize?: false
        )

      refute ActorOrgWalletFunded.match?(funded_actor, %{subject: changeset}, [])
    end

    test "a forged nil organization_id on an update is refused — the row's org answers", %{
      version: version
    } do
      # The exploit this closes: route the update by its nil attribute
      # and it takes the create path — the actor's WELCOME-FUNDED
      # personal org — while the real row's org is drained.
      stub_scale()

      {org, _wallet, owner} = funded_org_owner!()

      instance =
        Instance.create!(%{name: "Forge Nil", app_version_id: version.id, env_vars: %{}},
          actor: owner
        )

      stopped =
        Enum.reduce([:deploying, :starting, :running, :stopped], instance, fn status, acc ->
          {:ok, next} = InstanceK8s.update_status(acc, status, nil)
          next
        end)

      InstanceFixtures.pin!(stopped, namespace: "fluxvale-app-#{instance.id}")

      BillingFixtures.drain_wallet!(org)

      changeset = Ash.Changeset.for_update(stopped, :start, %{}, actor: owner)
      forged = %{changeset | data: %{stopped | organization_id: nil}}

      assert {:error, %Ash.Error.Forbidden{}} = Instance.start(forged, actor: owner)
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
