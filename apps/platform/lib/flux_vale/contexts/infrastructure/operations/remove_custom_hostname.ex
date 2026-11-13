defmodule FluxVale.Infrastructure.Operations.RemoveCustomHostname do
  @moduledoc """
  The member's custom-address remove (S6): delete the row's access edge
  first, then the `InstanceHostname` row, then re-render the resolver
  view best-effort.

  The order is the false-claim discipline in reverse: a route whose row
  is gone would still answer at the edge with no record of why, so the
  routes go while the row still names them. An unattached instance has
  no routes to remove (the mint skipped the cluster too), so the
  cluster limb is skipped entirely for it.

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

  defp route_missing?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{resource: AccessRoute}, &1))
  end

  defp route_missing?(_other), do: false

  defp read_opts(actor, authorize?, nil), do: [actor: actor, authorize?: authorize?]

  defp read_opts(actor, authorize?, context) do
    [actor: actor, authorize?: authorize?, context: context]
  end
end
