defmodule FluxVale.Infrastructure.Operations.EdgeRoutesDavPrefixGuardTest do
  @moduledoc false

  # The blank-path_prefix guard on the access /dav mint: a nil/blank
  # `:file_access` path_prefix would strip the PathPrefix clause and
  # mint a bare-Host router shadow-capable against the app route —
  # the guard skips + logs instead.

  # async: false — stubs the global :file_access app-env block (the
  # reconcile_topuptest precedent).

  use FluxVale.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    User.create!("dav-guard-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp file_access_instance! do
    # file_access is catalog-declared on the app VERSION and derived at
    # create (DeriveFromAppVersion) — never a direct create input.
    version = InstanceFixtures.app_version!(%{file_access: true})
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(
        %{name: "App", app_version_id: version.id, env_vars: %{}, storage_gb: 10},
        actor: user()
      )

    InstanceFixtures.pin!(instance,
      namespace: "fluxvale-app-#{instance.id}",
      deployed_at: DateTime.utc_now()
    )
  end

  test "a blank file_access path_prefix config skips the dav route — never a bare-Host shadow" do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    instance = file_access_instance!()
    ns = "fluxvale-app-#{instance.id}"

    stub(Service, :create, fn _kc, ^ns, "wake", _spec -> {:ok, %{}} end)

    stub(Middleware, :create, fn
      _kc, ^ns, "fluxvale-access-wake", _spec -> {:ok, %{}}
      _kc, ^ns, "fluxvale-activity", _spec -> {:ok, %{}}
    end)

    file_access_config = Application.fetch_env!(:flux_vale, :file_access)

    Application.put_env(
      :flux_vale,
      :file_access,
      Keyword.put(file_access_config, :path_prefix, nil)
    )

    on_exit(fn -> Application.put_env(:flux_vale, :file_access, file_access_config) end)

    stub(Ingress, :create, fn
      _kc, ^ns, "access-" <> _tail, %{path_prefix: _prefix} ->
        flunk("a nil prefix must skip the dav mint, not carry it through")

      _kc, ^ns, "access-" <> _tail, _spec ->
        # The app route mints as usual.
        {:ok, %{}}
    end)

    log =
      capture_log(fn ->
        assert :ok = EdgeRoutes.apply_access_serving(%{}, %{id: Ash.UUID.generate()}, instance)
      end)

    assert log =~ "bare-Host router"
    assert log =~ "skipping the /dav route"
  end
end
