defmodule FluxVale.Infrastructure.Operations.ReadBackupCredentialTest do
  @moduledoc false

  # #222 (ADR-0037 §4): the panel's repo-password reveal — a live read of
  # the namespace's `backup-config` Secret, the credential's only home.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Operations.ReadBackupCredential
  alias FluxVale.TestSupport.InstanceFixtures

  defp instance(attrs) do
    # A real Cluster row — kubeconfig_for resolves placement through it
    # (nil is an Ash.get error, not the path under test).
    cluster = InstanceFixtures.local_cluster!()

    base = %{namespace: "fluxvale-app-1", cluster_id: cluster.id}
    Map.merge(base, Map.new(attrs))
  end

  defp call(attrs \\ []) do
    subject = instance(attrs)
    ReadBackupCredential.call(subject)
  end

  test "reads the repo password off the namespace's backup-config Secret" do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    expect(Secret, :get_data, fn _kc, "fluxvale-app-1", "backup-config" ->
      {:ok,
       %{
         "RESTIC_REPOSITORY" => "s3:https://account.r2.cloudflarestorage.com/kavita",
         "RESTIC_PASSWORD" => "Q2hhbmdlVGhpc1RvQVNlY3JldA",
         "AWS_ACCESS_KEY_ID" => "AKIAIOSFODNN7EXAMPLE",
         "AWS_SECRET_ACCESS_KEY" => "secret"
       }}
    end)

    assert {:ok, %{repo_password: "Q2hhbmdlVGhpc1RvQVNlY3JldA"}} = call()
  end

  test "a never-deployed instance has no credential yet" do
    assert {:error, :not_deployed} = call(namespace: nil)
  end

  test "a missing Secret is :not_found (never saved, or the namespace went)" do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    expect(Secret, :get_data, fn _kc, "fluxvale-app-1", "backup-config" ->
      {:error, %Error{reason: :not_found}}
    end)

    assert {:error, :not_found} = call()
  end

  test "a kubeconfig failure propagates (transient — UI says try again)" do
    stub(K8s, :kubeconfig, fn nil -> {:error, %Error{reason: :connection_error}} end)

    assert {:error, %Error{}} = call()
  end

  test "a Secret without the password is malformed (the platform is its only writer)" do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    expect(Secret, :get_data, fn _kc, _ns, _name ->
      {:ok, %{"RESTIC_REPOSITORY" => "s3:https://example/bucket"}}
    end)

    assert {:error, :malformed} = call()
  end

  test "an empty password is malformed, not a blank credential to show" do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    expect(Secret, :get_data, fn _kc, _ns, _name ->
      {:ok, %{"RESTIC_PASSWORD" => ""}}
    end)

    assert {:error, :malformed} = call()
  end
end
