defmodule FluxVale.Infrastructure.StorageRequestPubSubTest do
  @moduledoc """
  #250's liveness contract: every request write publishes on the
  operator queue's static topic (`storage_requests:queue` — the sidebar
  badge and the live queue) and on the instance page's own request topic
  (`instances:<id>:storage-requests`). No polling, no email.
  """

  # The queue topic is static and global by design (the sidebar badge
  # subscribes on every admin page), so this file must not run
  # alongside other publishers — its subscribes would receive their
  # notifications. Async modules are sequential internally.
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.StorageClass
  alias FluxVale.Infrastructure.StorageRequest
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.StorageRequestFixtures

  setup do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    user = AccountsFixtures.user!()
    version = InstanceFixtures.app_version!(default_storage_gb: 10)
    InstanceFixtures.local_cluster!()

    instance =
      version
      |> InstanceFixtures.instance!(user)
      |> InstanceFixtures.pin!(namespace: "fluxvale-app-instance")
      |> InstanceFixtures.walk_to!(:stopped)

    {:ok, user: user, instance: instance}
  end

  test "create publishes on the queue and the instance request topic", %{
    user: user,
    instance: instance
  } do
    subscribe(instance)

    request = StorageRequestFixtures.request!(instance, user)

    assert_published(:request, request.id)
  end

  test "approve publishes on both topics", %{user: user, instance: instance} do
    admin = AccountsFixtures.platform_admin!()
    stub(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)
    request = StorageRequestFixtures.request!(instance, user)

    subscribe(instance)
    {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)

    assert_published(:approve, approved.id)
  end

  test "reject publishes on both topics", %{user: user, instance: instance} do
    admin = AccountsFixtures.platform_admin!()
    request = StorageRequestFixtures.request!(instance, user)

    subscribe(instance)
    {:ok, rejected} = StorageRequest.reject(request, %{rejection_reason: "No"}, actor: admin)

    assert_published(:reject, rejected.id)
  end

  test "mark_applied publishes on both topics", %{user: user, instance: instance} do
    admin = AccountsFixtures.platform_admin!()
    stub(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)
    request = StorageRequestFixtures.request!(instance, user)
    {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)

    subscribe(instance)
    {:ok, applied} = StorageRequest.mark_applied(approved, %{}, authorize?: false)

    assert_published(:mark_applied, applied.id)
  end

  test "mark_apply_failed publishes on both topics", %{user: user, instance: instance} do
    admin = AccountsFixtures.platform_admin!()
    stub(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)
    request = StorageRequestFixtures.request!(instance, user)
    {:ok, approved} = StorageRequest.approve(request, %{}, actor: admin)

    subscribe(instance)

    {:ok, failed} =
      StorageRequest.mark_apply_failed(approved, %{error: "boom"}, authorize?: false)

    assert_published(:mark_apply_failed, failed.id)
  end

  defp subscribe(instance) do
    Phoenix.PubSub.subscribe(FluxVale.PubSub, "storage_requests:queue")

    Phoenix.PubSub.subscribe(
      FluxVale.PubSub,
      "instances:#{instance.id}:storage-requests"
    )
  end

  # Both topics, both carrying the row's notification.
  defp assert_published(action, request_id) do
    for _topic <- 1..2 do
      assert_receive %Ash.Notifier.Notification{
        resource: StorageRequest,
        action: %{name: ^action},
        data: notified
      }

      assert notified.id == request_id
    end
  end
end
