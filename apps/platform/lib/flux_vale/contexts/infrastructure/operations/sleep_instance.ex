defmodule FluxVale.Infrastructure.Operations.SleepInstance do
  @moduledoc """
  Sleeps a `:running` Instance (#203, ADR-0036): scales the Deployment
  to 0 (the Okteto pattern — PVC, Services and routes stay) and flips
  the edge routes to wake mode, so the next visitor lands on the wake
  endpoint instead of a connectionless Service.

  Billing needs no code here: leaving `:running` folds the running
  anchor (MaintainAnchors) and the storage anchor keeps accruing — a
  sleeping instance settles at storage-only, exactly a stopped one
  (ADR-0028 §2).

  Failure posture, in apply order:

  - scale fails → `:error` (`:stop_failed` copy fits: "we couldn't
    stop your app"); the instance keeps serving and the row stays
    `:error` — the sweep only ever reads `:running`, so recovery is
    the owner's retry (a rare, loudly-surfaced shape, not a loop).
  - edge flip fails after a successful scale → `:stopped`, NOT
    `:sleeping`: the routes still point at the app Service, so traffic
    would 503 with nobody able to wake it. Stopped is the pre-#203
    degraded-but-honest shape (owner Start works, ingress is already
    correct).
  - gateway serve rewrite fails after `:sleeping` landed (#273,
    ADR-0039 §6's sleep-side half) → `:stopped`: the gateway's entry
    still targets the app Service, so a sleeping ATTACHED instance
    would serve 502 with nobody able to wake it through the gateway.
    Same honest shape — owner Start works.

  The rewrite runs only for an attached instance (an `access_routes`
  row): the gateway's config must point the instance's port at the
  platform's wake endpoint while it sleeps, or #273's intercept has
  nothing to answer.
  """

  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Infrastructure.AccessProvider
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  @doc """
  Scales to zero, flips the edge, lands `:sleeping`. Returns `{:ok,
  instance}` with the `status` attribute carrying the outcome — or
  `{:error, reason}` when the `:sleeping` status write itself fails
  (the sweep's retry owns the pass; nothing was slept).
  """
  @spec call(Instance.t()) :: {:ok, Instance.t()} | {:error, term()}
  def call(%{status: :running} = instance) do
    case InstanceK8s.kubeconfig_for(instance) do
      {:ok, kubeconfig} ->
        scale_then_flip(kubeconfig, instance)

      {:error, error} ->
        sleep_failed(instance, error)
    end
  end

  # A concurrent writer moved the state on — nothing to sleep.
  def call(instance), do: {:ok, instance}

  defp scale_then_flip(kubeconfig, instance) do
    case Deployment.scale(kubeconfig, instance.namespace, "app", 0) do
      {:ok, _deployment} -> flip_edge(kubeconfig, instance)
      {:error, error} -> sleep_failed(instance, error)
    end
  end

  # The scale landed, so the workload is down whatever happens next —
  # the remaining question is only whether visitors can wake it.
  defp flip_edge(kubeconfig, instance) do
    case EdgeRoutes.apply_wake(kubeconfig, instance) do
      :ok ->
        land_sleeping(instance)

      {:error, error} ->
        # Routes still point at the app Service: traffic would 503 with
        # nobody able to wake it. Stopped is the honest shape — owner
        # Start works, the routes are already correct (the pre-#203
        # stopped behavior, billing included).
        InstanceK8s.update_status(
          instance,
          :stopped,
          "Slept without wake routing; owner can start it again (#{InstanceK8s.format_error(error)})"
        )
    end
  end

  # The status write lands :sleeping FIRST, deliberately (ADR-0039 §6's
  # sleep-side half): the gateway's serve config is regenerated from the
  # rows' current statuses, so a rewrite that ran before this write would
  # read :running and re-target the app — the exact gap #273 closes. A
  # failed status write propagates unchanged (the sweep's retry owns it).
  defp land_sleeping(instance) do
    with {:ok, sleeping} <- InstanceK8s.update_status(instance, :sleeping, nil) do
      rewrite_gateway_routing(sleeping)
    end
  end

  # Only an ATTACHED instance rides the gateway: an unattached private
  # row's whole story is the edge posture above (no route, nothing to
  # wake), and every non-sleeping status targets the app by design. A
  # read that FAILED is not "unattached" — treating it as one would land
  # a silently unwakeable `:sleeping`, so it takes the honest
  # `:stopped` arm too.
  defp rewrite_gateway_routing(sleeping) do
    case AccessRoute.get_by_instance(sleeping.id, authorize?: false) do
      {:ok, route} ->
        rewrite_route(sleeping, route)

      {:error, error} ->
        if route_not_found?(error) do
          {:ok, sleeping}
        else
          route_rewrite_failed(sleeping, error)
        end
    end
  end

  defp rewrite_route(sleeping, route) do
    # The load returns the ROUTE with its gateway populated.
    with {:ok, route} <- Ash.load(route, :gateway, authorize?: false),
         gateway = route.gateway,
         {:ok, _serve_config} <- AccessProvider.impl_for(gateway).refresh_routes(gateway) do
      {:ok, sleeping}
    else
      {:error, error} ->
        route_rewrite_failed(sleeping, error)
    end
  end

  # The gateway's serve entry still targets the app Service, so a
  # sleeping attached instance would serve 502 with nobody able to wake
  # it through the gateway. Stopped is the honest pre-wake shape —
  # owner Start works — the edge-flip clause's posture, gateway-flavored
  # (#273).
  defp route_rewrite_failed(sleeping, error) do
    InstanceK8s.update_status(
      sleeping,
      :stopped,
      "Slept without gateway wake routing; owner can start it again (#{InstanceK8s.format_error(error)})"
    )
  end

  defp route_not_found?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  # coveralls-ignore-start - defensive: get_by_instance returns Invalid
  # shapes today; the catch-all is the guard if that ever widens (a
  # non-NotFound error takes the honest landing either way).
  defp route_not_found?(_other), do: false
  # coveralls-ignore-stop

  defp sleep_failed(instance, error) do
    InstanceK8s.update_status(
      instance,
      :error,
      "Sleep failed: #{InstanceK8s.format_error(error)}",
      :stop_failed
    )
  end
end
