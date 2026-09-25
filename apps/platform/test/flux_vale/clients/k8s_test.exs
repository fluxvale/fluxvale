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

  describe "kubeconfig/1" do
    test "nil delegates to the in-cluster path" do
      assert {:error, %K8s.Error{reason: :connection_error, message: msg}} = K8s.kubeconfig(nil)
      assert msg =~ "service-account"
    end

    test "loads a kubeconfig file path (the first kubeconfig_ref format, #73)" do
      path =
        Path.join(System.tmp_dir!(), "fluxvale-kubeconfig-test-#{System.unique_integer()}.yaml")

      on_exit(fn -> File.rm(path) end)

      File.write!(path, """
      apiVersion: v1
      kind: Config
      clusters:
        - name: k3d-local
          cluster:
            server: https://127.0.0.1:6443
      contexts:
        - name: k3d-local
          context:
            cluster: k3d-local
            user: admin
      current-context: k3d-local
      users:
        - name: admin
          user:
            token: test-token
      """)

      assert {:ok, kubeconfig} = K8s.kubeconfig(path)
      assert kubeconfig.current_context == "k3d-local"
    end

    test "a missing file is a clean connection error" do
      missing =
        Path.join(System.tmp_dir!(), "fluxvale-kubeconfig-absent-#{System.unique_integer()}")

      assert {:error, %K8s.Error{reason: :connection_error, message: msg}} =
               K8s.kubeconfig(missing)

      assert msg =~ "not found"
    end

    test "a file with no context or clusters is invalid" do
      path =
        Path.join(System.tmp_dir!(), "fluxvale-kubeconfig-empty-#{System.unique_integer()}.yaml")

      on_exit(fn -> File.rm(path) end)

      File.write!(path, "apiVersion: v1\nkind: Config\n")

      assert {:error, %K8s.Error{reason: :connection_error}} = K8s.kubeconfig(path)
    end
  end
end
