defmodule FluxVale.Infrastructure.Operations.StorageRequestOperationsTest do
  @moduledoc """
  The storage-request workflow end to end (#250, ADR-0046): request →
  approve → the online `:grow_storage` apply (the PVC spec grows, the
  request lands applied), reject with feedback, a failed apply that
  leaves the durable approval in place, the retry (and its idempotent
  convergence when the instance already reached the target), and the
  member's inability to decide.

  The K8s surface is Mimic-stubbed exactly like the grow-storage
  suites; expects are verified on exit, so a green test proves the
  cluster calls it claims.
  """

  use FluxVale.DataCase, async: true
  use Mimic

  setup :verify_on_exit!

  alias Ash.Error.Changes.InvalidAttribute
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.StorageClass
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.ApplyStorageRequest
  alias FluxVale.Infrastructure.StorageRequest
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.StorageRequestFixtures

  setup do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    :ok
  end

  defp admin!, do: AccountsFixtures.platform_admin!()
  defp user!, do: AccountsFixtures.user!()

  # A deployed, running instance at 10 GB — the online growth's legal
  # status and a cluster-managed row (namespace pinned).
  defp running_deployed!(user) do
    version = InstanceFixtures.app_version!(default_storage_gb: 10, monthly_cents: 100)
    InstanceFixtures.local_cluster!()

    created =
      Instance.create!(
        %{name: "Storage op", app_version_id: version.id, env_vars: %{}},
        actor: user
      )

    running = InstanceFixtures.walk_to!(created, :running)
    InstanceFixtures.pin!(running, namespace: "fluxvale-app-#{created.id}")
  end

  # The N→M growth's cluster: quota at the new storage, the live claim's
  # 10 Gi, the PVC patch at the requested total.
  defp allow_expansion!,
    do: stub(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

  # A stub, not an expect: the failure/retry test runs two growths, and
  # each one re-applies the quota.
  defp stub_quota!(expected_gb) do
    stub(ResourceQuota, :create, fn _kc, _ns, "app-quota", spec ->
      assert spec.storage == expected_gb
      {:ok, %{}}
    end)
  end

  defp stub_live_claim!(gb) do
    stub(PersistentVolumeClaim, :get, fn _kc, _ns, "app-data" ->
      {:ok, %{"spec" => %{"resources" => %{"requests" => %{"storage" => "#{gb}Gi"}}}}}
    end)
  end

  defp expect_pvc_growth!(expected_gb) do
    expect(PersistentVolumeClaim, :upsert, fn _kc, _ns, "app-data", spec ->
      assert spec.size == "#{expected_gb}Gi"
      {:ok, %{}}
    end)
  end

  test "request → approve grows the PVC and lands applied" do
    admin = admin!()
    user = user!()
    instance = running_deployed!(user)
    request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

    allow_expansion!()
    stub_quota!(150)
    stub_live_claim!(10)
    expect_pvc_growth!(150)

    # No pod roll on an N→M grow: the deployment is untouched.
    reject(Deployment, :get, 3)
    reject(Deployment, :create, 4)

    assert {:ok, applied} = Infrastructure.approve_storage_request(admin, request.id)

    assert applied.status == :applied
    assert applied.applied_at
    assert applied.decided_by_user_id == admin.id
    assert applied.decided_at
    assert applied.apply_error == nil

    grown = Ash.get!(Instance, instance.id, authorize?: false)
    assert grown.storage_gb == 150
  end

  test "reject closes the request with the member-visible feedback" do
    admin = admin!()
    user = user!()
    instance = running_deployed!(user)
    request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

    assert {:ok, rejected} =
             Infrastructure.reject_storage_request(
               admin,
               request.id,
               "We can't attach that capacity right now"
             )

    assert rejected.status == :rejected
    assert rejected.rejection_reason == "We can't attach that capacity right now"

    unchanged = Ash.get!(Instance, instance.id, authorize?: false)
    assert unchanged.storage_gb == 10
  end

  test "a failed apply leaves the decision durable and retry converges" do
    admin = admin!()
    user = user!()
    instance = running_deployed!(user)
    request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

    allow_expansion!()
    stub_quota!(150)
    stub_live_claim!(10)

    stub(PersistentVolumeClaim, :upsert, fn _kc, _ns, "app-data", _spec ->
      {:error, %Error{reason: :api_error, message: "the API server refused the patch"}}
    end)

    assert {:ok, failed} = Infrastructure.approve_storage_request(admin, request.id)

    # The decision is durable; the mechanical step is retryable.
    assert failed.status == :approved
    assert failed.decided_by_user_id == admin.id
    assert failed.decided_at
    assert failed.apply_error
    assert failed.applied_at == nil

    unchanged = Ash.get!(Instance, instance.id, authorize?: false)
    assert unchanged.storage_gb == 10

    # The retry re-runs the same apply and succeeds.
    expect_pvc_growth!(150)

    assert {:ok, applied} = Infrastructure.retry_storage_request(admin, failed.id)

    assert applied.status == :applied
    assert applied.apply_error == nil
    assert applied.applied_at

    grown = Ash.get!(Instance, instance.id, authorize?: false)
    assert grown.storage_gb == 150
  end

  test "retry is idempotent when the instance already reached the target" do
    admin = admin!()
    user = user!()
    instance = running_deployed!(user)
    request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

    allow_expansion!()

    # The approved decision without the operation's apply (the crash
    # window): the row is approved, then the instance reaches 150 GB by
    # another writer (here the resize-equivalent growth).
    {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)

    expect_pvc_growth!(150)
    stub_quota!(150)
    stub_live_claim!(10)
    {:ok, _grown} = Instance.grow_storage(instance, %{storage_gb: 150}, authorize?: false)

    # The retry sees the target already reached: no second PVC patch, no
    # no-op refusal — it marks the request applied.
    reject(PersistentVolumeClaim, :upsert, 4)
    reject(ResourceQuota, :create, 4)

    assert {:ok, applied} = Infrastructure.retry_storage_request(admin, approved.id)

    assert applied.status == :applied
    assert applied.apply_error == nil
    assert applied.applied_at
  end

  test "an apply against a deleting instance fails honestly and stays approved" do
    admin = admin!()
    user = user!()
    instance = running_deployed!(user)
    request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})
    allow_expansion!()

    {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)

    _deleting = InstanceFixtures.pin!(instance, status: :deleting)

    assert {:ok, failed} = Infrastructure.retry_storage_request(admin, approved.id)

    assert failed.status == :approved
    assert failed.apply_error =~ "cannot grow storage for an instance in deleting state"
  end

  test "an apply for a vanished instance records the honest failure" do
    admin = admin!()
    user = user!()
    instance = running_deployed!(user)

    %StorageRequest{} =
      request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

    allow_expansion!()
    {:ok, %StorageRequest{} = approved} = StorageRequest.approve(request, %{}, actor: admin)

    # The row's FK cascades with the instance; the struct arm is the
    # defensive race the apply must still answer.
    vanished = %StorageRequest{approved | instance_id: Ash.UUID.generate()}

    assert {:ok, failed} =
             ApplyStorageRequest.call(vanished)

    assert failed.id == request.id
    assert failed.status == :approved
    assert failed.apply_error == "the instance no longer exists"
  end

  test "a pathological error is truncated at the internal column's bound" do
    Mimic.copy(Instance)

    long = String.duplicate("x", 1_500)

    stub(Instance, :grow_storage, fn _instance, _params, _opts ->
      {:error,
       %Ash.Error.Invalid{
         errors: [InvalidAttribute.exception(field: :storage_gb, message: long)]
       }}
    end)

    admin = admin!()
    user = user!()
    instance = running_deployed!(user)
    request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

    allow_expansion!()

    assert {:ok, failed} = Infrastructure.approve_storage_request(admin, request.id)
    assert failed.status == :approved
    assert is_binary(failed.apply_error)
    assert String.length(failed.apply_error) == 1_000
  end

  test "a member cannot approve through the operation" do
    user = user!()
    instance = running_deployed!(user)
    request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})
    allow_expansion!()

    assert {:error, %Ash.Error.Forbidden{}} =
             Infrastructure.approve_storage_request(user, request.id)
  end

  test "an unknown request id is not found" do
    assert {:error, error} =
             Infrastructure.approve_storage_request(admin!(), Ash.UUID.generate())

    assert Exception.message(error) =~ "not found"
  end

  test "a blank rejection feedback is refused" do
    admin = admin!()
    user = user!()
    instance = running_deployed!(user)
    request = StorageRequestFixtures.request!(instance, user, %{requested_gb: 150})

    assert {:error, error} = Infrastructure.reject_storage_request(admin, request.id, "   ")
    assert Exception.message(error) =~ "rejection feedback is required"
  end
end
