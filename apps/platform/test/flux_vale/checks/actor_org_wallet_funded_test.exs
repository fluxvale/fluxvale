defmodule FluxVale.Checks.ActorOrgWalletFundedTest do
  @moduledoc false

  # #124's gate: an Ash policy check (the API can't walk around it),
  # wired to Instance create + start. An org without a wallet is
  # unfunded — balance 0 by definition.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Accounts
  alias FluxVale.Billing
  alias FluxVale.Checks.ActorOrgWalletFunded
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()
    {:ok, version: version}
  end

  describe "org_funded?/1" do
    test "a positive balance funds the org" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      assert ActorOrgWalletFunded.org_funded?(org.id)
    end

    test "an empty wallet does not fund the org" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)
      {:ok, wallet} = Billing.ensure_wallet(org)
      {:ok, _debit} = Billing.debit_wallet(wallet, 10_000 * 10_000)

      refute ActorOrgWalletFunded.org_funded?(org.id)
    end

    test "a wallet-less org is unfunded — balance 0 by definition" do
      # Direct User.create (not the funding fixture): the JIT org exists,
      # nothing ensured a wallet — the gate reads it as 0.
      user =
        User.create!("walletless-#{System.unique_integer()}@fluxvale.test", %{},
          authorize?: false
        )

      {:ok, org} = Accounts.personal_org_for_user(user.id, authorize?: false)

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
      funded = AccountsFixtures.user!()

      assert {:ok, _instance} =
               Instance.create(
                 %{name: "Funded", app_version_id: version.id, env_vars: %{}},
                 actor: funded
               )

      drained = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(drained)
      {:ok, wallet} = Billing.ensure_wallet(org)
      {:ok, _debit} = Billing.debit_wallet(wallet, 10_000 * 10_000)

      assert {:error, %Ash.Error.Forbidden{}} =
               Instance.create(
                 %{name: "Drained", app_version_id: version.id, env_vars: %{}},
                 actor: drained
               )
    end

    test "a wallet-less org is not funded — creation is forbidden", %{version: version} do
      # Direct User.create: the JIT org exists, nothing ensured a wallet.
      user =
        User.create!("nowallet-#{System.unique_integer()}@fluxvale.test", %{}, authorize?: false)

      assert {:error, %Ash.Error.Forbidden{}} =
               Instance.create(
                 %{name: "NoWallet", app_version_id: version.id, env_vars: %{}},
                 actor: user
               )
    end
  end

  describe "the Instance start gate" do
    test "start is forbidden while the wallet is empty, open after a top-up", %{
      version: version
    } do
      stub_scale()

      user = AccountsFixtures.user!()

      instance =
        Instance.create!(%{name: "Gate", app_version_id: version.id, env_vars: %{}}, actor: user)

      stopped =
        Enum.reduce([:deploying, :starting, :running, :stopped], instance, fn status, acc ->
          {:ok, next} = InstanceK8s.update_status(acc, status, nil)
          next
        end)

      InstanceFixtures.pin!(stopped, namespace: "fluxvale-app-#{instance.id}")

      org = AccountsFixtures.personal_org!(user)
      {:ok, wallet} = Billing.ensure_wallet(org)
      {:ok, _debit} = Billing.debit_wallet(wallet, 10_000 * 10_000)

      assert {:error, %Ash.Error.Forbidden{}} = Instance.start(stopped, actor: user)

      {:ok, _grant} = Billing.grant_credits(wallet, 100)
      assert {:ok, starting} = Instance.start(stopped, actor: user)
      assert starting.status == :starting
    end
  end

  defp stub_scale do
    stub(FluxVale.Clients.K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(FluxVale.Clients.K8s.Resources.Deployment, :scale, fn _kc, _ns, _n, 1 -> {:ok, %{}} end)
  end
end
