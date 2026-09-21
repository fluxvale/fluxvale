defmodule FluxVale.Clients.K8sTest do
  use ExUnit.Case, async: true

  alias FluxVale.Clients.K8s

  describe "enabled?/0" do
    test "is false in the native test env (no SA files)" do
      # ADR-0020: mix test stays native — the cluster is for k8s-touching
      # integration work, not unit tests.
      refute K8s.enabled?()
    end
  end

  describe "kubeconfig/0" do
    test "returns a connection error without SA files" do
      assert {:error, %K8s.Error{reason: :connection_error}} = K8s.kubeconfig()
    end
  end
end
