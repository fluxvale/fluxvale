defmodule FluxVale.Infrastructure.InstancePubSubTest do
  @moduledoc false

  # The #74 broadcast contract: every status-writing action publishes the
  # record on instances:<id> — the LiveView surfaces' single source of
  # liveness. Funnel actions plus the direct writers, and teardown's
  # destroy (the one change that never passes through the funnel).

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    user = User.create!("pubsub-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

    instance = Instance.create!(%{name: "PubSub", app_version_id: version.id}, actor: user)

    {:ok, instance: instance, user: user, version: version}
  end

  test "update_status publishes the updated record", %{instance: instance} do
    starting = InstanceFixtures.walk_to!(instance, :starting)

    Phoenix.PubSub.subscribe(FluxVale.PubSub, "instances:#{instance.id}")

    {:ok, running} = InstanceK8s.update_status(starting, :running, "Ready")

    assert_received %Ash.Notifier.Notification{data: notified, action: %{name: :update_status}}
    assert notified.id == running.id
    assert notified.status == :running
  end

  test "deploy publishes (the direct :deploying write)", %{instance: instance, user: user} do
    Phoenix.PubSub.subscribe(FluxVale.PubSub, "instances:#{instance.id}")

    # Inline testing executes the enqueued trigger in-process; an erroring
    # kubeconfig stub makes the K8s leg fail deterministically, so the
    # funnel's :error write also publishes — also on-topic.
    stub(K8s, :kubeconfig, fn nil -> {:error, :no_kubeconfig} end)

    {:ok, deploying} = Instance.deploy(instance, actor: user)

    assert_receive %Ash.Notifier.Notification{data: notified, action: %{name: :deploy}}
    assert notified.id == deploying.id

    assert_receive %Ash.Notifier.Notification{
                     data: %{status: :error},
                     action: %{name: :update_status}
                   },
                   1_000
  end

  test "destroy publishes — teardown's hard delete is observable", %{
    instance: instance,
    user: user
  } do
    Phoenix.PubSub.subscribe(FluxVale.PubSub, "instances:#{instance.id}")

    # Never deployed: delete hard-deletes the row synchronously.
    Instance.delete(instance.id, actor: user)

    assert_receive %Ash.Notifier.Notification{action: %{name: :destroy}, data: notified}
    assert notified.id == instance.id
  end
end
