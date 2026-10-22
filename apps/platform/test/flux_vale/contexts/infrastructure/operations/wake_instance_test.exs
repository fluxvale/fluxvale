defmodule FluxVale.Infrastructure.Operations.WakeInstanceTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.WakeInstance
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    User.create!("wake-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp sleeping_instance!(user) do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(%{name: "App", app_version_id: version.id, env_vars: %{}}, actor: user)

    instance
    |> InstanceFixtures.pin!(
      namespace: "fluxvale-app-#{instance.id}",
      deployed_at: DateTime.utc_now()
    )
    |> InstanceFixtures.walk_to!(:sleeping)
  end

  defp org_of(instance) do
    Ash.get!(Organization, instance.organization_id, authorize?: false)
  end

  defp stub_start do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
  end

  test "a funded org's sleeping instance wakes — start from the actorless edge" do
    stub_start()
    owner = user()
    instance = sleeping_instance!(owner)
    BillingFixtures.funded_wallet!(org: org_of(instance))

    assert {:ok, waking} = WakeInstance.call(instance)
    assert waking.status == :starting
  end

  # The org starts with the JIT welcome grant (#122) — the sleeping
  # walk needs nothing funded, so the drain lands the exact target
  # (posting never checks balance, so drains overshoot freely).
  defp drain_org!(instance) do
    org = org_of(instance)
    {:ok, wallet} = Billing.ensure_wallet(org)
    {:ok, balance_cents} = Billing.balance(wallet, authorize?: false)

    if balance_cents > 0 do
      # cents → micro-cents (the wallet's unit).
      Billing.debit_wallet(wallet, balance_cents * 10_000)
    end

    :ok
  end

  test "an unfunded org's sleeping instance stays asleep (#124's gate, edge-shaped)" do
    stub_start()
    owner = user()
    instance = sleeping_instance!(owner)
    drain_org!(instance)

    assert {:error, :unfunded} = WakeInstance.call(instance)

    slept = Instance.get_by_id!(instance.id, authorize?: false)
    assert slept.status == :sleeping
  end

  test "a non-sleeping instance is a no-op — the caller answers from status" do
    stub_start()
    owner = user()
    instance = sleeping_instance!(owner)

    # The funnel's legal wake path, driven by hand: :starting then
    # :running (the state machine has no sleeping → running).
    {:ok, waking} = InstanceK8s.update_status(instance, :starting, nil)
    {:ok, running} = InstanceK8s.update_status(waking, :running, nil)

    assert {:ok, ^running} = WakeInstance.call(running)
  end
end
