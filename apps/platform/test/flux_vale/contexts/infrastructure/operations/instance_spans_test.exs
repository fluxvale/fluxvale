defmodule FluxVale.Infrastructure.Operations.InstanceSpansTest do
  @moduledoc """
  The Instance deploy/reconcile custom spans (ADR-0012 Am. 1) — name,
  identifying attributes, and `:error` status on the failure flips.

  `FluxVale.TestSupport.Tracing` swaps the batch exporter VM-globally —
  hence `async: false`. The matchers scope on the unique instance id,
  never just the span name (names repeat across the suite's history in
  the shared batch buffer).
  """

  use FluxVale.DataCase, async: false
  use Mimic

  import FluxVale.TestSupport.Tracing,
    only: [attribute_map: 1, refute_span_matching: 3, span_matching: 3]

  alias FluxVale.TestSupport.Tracing

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.DeployInstance
  alias FluxVale.Infrastructure.Operations.ReconcileInstance
  alias FluxVale.TestSupport.InstanceFixtures

  require Record

  # include/ isn't copied into _build for rebar3 deps — read it from the
  # dep tree (mix test always runs with the app dir as cwd).
  Record.defrecordp(
    :span,
    Record.extract(:span, from: "deps/opentelemetry/include/otel_span.hrl")
  )

  Record.defrecordp(
    :status,
    Record.extract(:status, from: "deps/opentelemetry_api/include/opentelemetry.hrl")
  )

  setup do
    Tracing.export_spans_to(self())

    on_exit(fn ->
      Tracing.restore()
    end)

    :ok
  end

  defp user do
    User.create!("span-watcher-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp creating!(attrs \\ %{}) do
    version = InstanceFixtures.app_version!(attrs)
    InstanceFixtures.local_cluster!()

    Instance.create!(
      %{name: "Spanned App", app_version_id: version.id, env_vars: %{}},
      actor: user()
    )
  end

  defp walk_to!(instance, target) do
    reached = InstanceFixtures.walk_to!(instance, target)

    InstanceFixtures.pin!(reached,
      namespace: "fluxvale-app-#{instance.id}",
      deployed_at: DateTime.utc_now()
    )
  end

  describe "instance.deploy spans" do
    test "the deploy orchestration is one span carrying instance identity" do
      stub_kubeconfig()
      stub_applies()

      instance = creating!()
      deploying = walk_to!(instance, :deploying)

      assert {:ok, %Instance{}} = DeployInstance.call(deploying)

      span = span_matching("instance.deploy", "instance.id", instance.id)
      attributes = attribute_map(span)

      assert Map.get(attributes, "instance.id") == instance.id
      assert attributes["instance.slug"] == instance.slug
      assert attributes["instance.namespace"] == "fluxvale-app-#{instance.id}"
    end

    test "a failed deploy marks the span :error" do
      stub(K8s, :kubeconfig, fn nil -> {:error, K8s.Error.connection_error("no SA files")} end)

      instance = creating!()
      deploying = walk_to!(instance, :deploying)

      assert {:ok, %Instance{}} = DeployInstance.call(deploying)

      span = span_matching("instance.deploy", "instance.id", instance.id)

      assert status(span(span, :status), :code) == :error
      assert status(span(span, :status), :message) =~ "no SA files"
    end

    test "a superseded deploy job starts no span" do
      instance = creating!()

      assert {:ok, %Instance{}} = DeployInstance.call(instance)

      refute_span_matching("instance.deploy", "instance.id", instance.id)
    end
  end

  describe "instance.reconcile spans" do
    test "the promote pass is one span" do
      stub_kubeconfig()

      stub(Deployment, :status, fn _kc, _ns, _name ->
        {:ok, %{replicas: 1, ready: 1, conditions: []}}
      end)

      instance = creating!()
      starting = walk_to!(instance, :starting)

      assert {:ok, %Instance{}} = ReconcileInstance.call(starting)

      span = span_matching("instance.reconcile", "instance.id", instance.id)
      attributes = attribute_map(span)

      assert Map.get(attributes, "instance.id") == instance.id
      assert attributes["instance.status"] == "starting"
    end

    test "a demotion marks the span :error" do
      stub_kubeconfig()

      stub(Deployment, :status, fn _kc, _ns, _name ->
        {:error, K8s.Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      instance = creating!()
      starting = walk_to!(instance, :starting)

      assert {:ok, %Instance{}} = ReconcileInstance.call(starting)

      span = span_matching("instance.reconcile", "instance.id", instance.id)

      assert status(span(span, :status), :code) == :error
    end
  end

  defp stub_kubeconfig do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
  end

  # Every operand the deploy applies — shapes are asserted by
  # deploy_instance_test; here they only need to succeed.
  defp stub_applies do
    # Namespace.create has no resource name (the namespace is the name)
    stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)

    for module <- [
          RoleBinding,
          ResourceQuota,
          NetworkPolicy,
          PersistentVolumeClaim,
          Secret,
          Deployment,
          Service,
          Ingress
        ] do
      stub(module, :create, fn _kc, _ns, _name, _spec -> {:ok, %{}} end)
    end
  end
end
