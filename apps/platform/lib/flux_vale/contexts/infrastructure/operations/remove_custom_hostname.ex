defmodule FluxVale.Infrastructure.Operations.RemoveCustomHostname do
  @moduledoc """
  The member's custom-address remove (S6): delete the row's edge
  routes first — the public custom route for a public instance (no
  pairing read: the exposure is the whole dispatch), the pairing-gated
  access routes for a private one — then the `InstanceHostname` row,
  then re-render the resolver view best-effort.

  The order is the false-claim discipline in reverse: a route whose row
  is gone would still answer at the edge with no record of why, so the
  routes go while the row still names them. An unattached private
  instance has no routes to remove (the mint skipped the cluster too),
  so the cluster limb is skipped entirely for it.

  After the row is gone the remove re-tells the app its remaining
  address (or drops the URL key) best-effort; a failure leaves the old
  value stale-but-working and converges on the next event or deploy.

  Ownership is the authorized hostname read (its policy rides the
  instance's org membership) plus the authorized instance read — a
  foreign row is a not-found before any cluster call (the
  AccessDomain.remove_via_api shape).
  """

  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.Infrastructure.Operations.SyncInstanceUrlEnv

  require Logger

  @doc """
  `{:ok, hostname}` or `{:error, reason}`. `opts` carry `actor:` /
  `authorize?:` / `context:`.
  """
  @spec call(Ash.UUID.t(), keyword()) :: {:ok, InstanceHostname.t()} | {:error, term()}
  def call(hostname_id, opts \\ []) do
    actor = opts[:actor]
    authorize? = Keyword.get(opts, :authorize?, true)
    read_opts = read_opts(actor, authorize?, opts[:context])

    with {:ok, hostname} <- Ash.get(InstanceHostname, hostname_id, read_opts),
         {:ok, hostname} <- Ash.load(hostname, :access_domain, read_opts),
         :ok <- ensure_custom(hostname.access_domain),
         {:ok, instance} <- Instance.get_by_id(hostname.instance_id, read_opts),
         :ok <- remove_edge(instance, hostname, read_opts),
         :ok <- destroy(hostname) do
      # The re-tell runs after the row is destroyed (the derivation
      # must not see the row just removed), before the resolver render.
      tell_app(instance)
      RenderAccessDNS.call()
      {:ok, hostname}
    end
  end

  # The default address's row is load-bearing (the instance's own
  # public/private hostname); removing it would unroute an address the
  # member never chose to lose. The platform row is not member surface
  # (the AccessDomain :remove guard's shape).
  defp ensure_custom(%{kind: :custom}), do: :ok
  defp ensure_custom(%{kind: :platform}), do: {:error, :platform_domain}

  # A never-deployed instance never minted a route — record-only on
  # the mint's side, record-only on the remove's: the delete-by-name
  # would 404-tolerate anyway, but the gate makes the contract
  # explicit instead of accidental (the same shape bda81d4a gave the
  # mint).
  defp remove_edge(%{namespace: nil}, _hostname, _read_opts), do: :ok

  # Public: the custom route lives on the public entrypoint, so the
  # public none limb takes it down — no pairing read (a stale
  # AccessRoute row must not detour the delete). The route goes BEFORE
  # the row destroy — call/2's order — while the row still names the
  # objects: a row destroyed under a standing route can never be named
  # by any later walk (the orphan a gate-2 finding proved survives even
  # a later exposure flip).
  defp remove_edge(%{exposure: :public} = instance, hostname, _read_opts) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance) do
      EdgeRoutes.apply_public_none_for_hostname(kubeconfig, instance, hostname)
    end
  end

  defp remove_edge(instance, hostname, read_opts) do
    case AccessRoute.get_by_instance(instance.id, read_opts) do
      {:ok, _route} ->
        with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance) do
          EdgeRoutes.apply_access_none_for_hostname(kubeconfig, instance, hostname)
        end

      {:error, error} ->
        if route_missing?(error) do
          :ok
        else
          {:error, error}
        end
    end
  end

  # authorize?: false — the ownership fence was the authorized reads
  # above (the instance delete stance); the row destroy itself is
  # system-only by policy.
  defp destroy(hostname), do: InstanceHostname.destroy(hostname, authorize?: false)

  # Best-effort re-tell: the address is gone either way, so a sync
  # failure is one warning and the remove still succeeds — the app's
  # env is stale-but-working and the delivery-aware retry converges on
  # the next event or deploy. Never an error from the remove.
  defp tell_app(instance) do
    case SyncInstanceUrlEnv.call(instance) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "instance address env sync after remove refused instance=#{instance.id} " <>
            "reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp route_missing?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{resource: AccessRoute}, &1))
  end

  defp route_missing?(_other), do: false

  defp read_opts(actor, authorize?, nil), do: [actor: actor, authorize?: authorize?]

  defp read_opts(actor, authorize?, context) do
    [actor: actor, authorize?: authorize?, context: context]
  end
end
