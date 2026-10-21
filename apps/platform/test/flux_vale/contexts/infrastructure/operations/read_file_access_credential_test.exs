defmodule FluxVale.Infrastructure.Operations.ReadFileAccessCredentialTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Operations.ReadFileAccessCredential
  alias FluxVale.TestSupport.InstanceFixtures

  defp instance(attrs) do
    # A real Cluster row — kubeconfig_for resolves placement through it
    # (nil is an Ash.get error, not the path under test).
    cluster = InstanceFixtures.local_cluster!()

    base = %{file_access: true, namespace: "fluxvale-app-1", cluster_id: cluster.id}
    Map.merge(base, Map.new(attrs))
  end

  defp call(attrs \\ []) do
    subject = instance(attrs)
    ReadFileAccessCredential.call(subject)
  end

  test "reads the credential off the namespace's file-access Secret" do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    expect(Secret, :get_data, fn _kc, "fluxvale-app-1", "file-access" ->
      {:ok, %{"RCLONE_USER" => "fluxvale", "RCLONE_PASS" => "s3cret"}}
    end)

    assert {:ok, %{username: "fluxvale", password: "s3cret"}} =
             call()
  end

  test "a never-deployed instance has no credential yet" do
    assert {:error, :not_deployed} = call(namespace: nil)
  end

  test "a missing Secret is :not_found (torn down, or predates file access)" do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    expect(Secret, :get_data, fn _kc, "fluxvale-app-1", "file-access" ->
      {:error, %Error{reason: :not_found}}
    end)

    assert {:error, :not_found} = call()
  end

  test "a non-file-access instance has no credential by construction" do
    assert {:error, :not_found} = call(file_access: false)
  end

  test "a kubeconfig failure propagates (transient — UI says try again)" do
    stub(K8s, :kubeconfig, fn nil -> {:error, %Error{reason: :connection_error}} end)

    assert {:error, %Error{}} = call()
  end

  test "a partial Secret read is malformed (the platform is its only writer)" do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    expect(Secret, :get_data, fn _kc, _ns, _name ->
      {:ok, %{"RCLONE_USER" => "fluxvale"}}
    end)

    assert {:error, :malformed} = call()
  end
end
