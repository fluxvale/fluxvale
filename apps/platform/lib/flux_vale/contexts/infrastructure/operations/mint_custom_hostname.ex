defmodule FluxVale.Infrastructure.Operations.MintCustomHostname do
  @moduledoc """
  The member's custom-address mint (S6, ADR-0040 §7): a `label` under a
  verified `:custom` `AccessDomain` the instance's org owns, recorded as
  one `InstanceHostname` row. This is the missing writer between a
  verified domain and a serving custom hostname — the edge and resolver
  arms consume the row as-is.

  The ownership fence is the authorized instance read (`Instance.get_by_id/2`:
  a foreign instance is a not-found, never a distinguishable 403), then
  the domain read with the same actor. The guards are separate so the
  caller can say which one failed: the domain must belong to the
  instance's org, be `:custom` (the platform domain already minted the
  default address), and be `:verified` (verify-by-issuance; a pending
  certificate never routes anyway).

  An ATTACHED instance's edge is re-applied for its current status after
  the row mints — a hostname that exists but routes nothing is the
  false claim the AttachInstance unwind stance refuses. If that apply
  fails, the just-minted row is destroyed (and any partial route
  removed) before the error returns; an unattached instance skips the
  cluster entirely, recording the row for the day it attaches.

  Pure DB work plus the one idempotent edge apply; the resolver view is
  derived state, so the `RenderAccessDNS` pass runs best-effort AFTER
  the row commits (a failed render never fails the mint).
  """

  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS

  @doc """
  `{:ok, hostname}` or `{:error, reason}` — `reason` being
  `:different_organization | :not_custom | :not_verified | Forbidden |
  term()`. `opts` carry `actor:` / `authorize?:` / `context:`.
  """
  @spec call(Ash.UUID.t(), Ash.UUID.t(), String.t(), keyword()) ::
          {:ok, InstanceHostname.t()} | {:error, term()}
  def call(instance_id, access_domain_id, label, opts \\ []) do
    actor = opts[:actor]
    authorize? = Keyword.get(opts, :authorize?, true)
    read_opts = read_opts(actor, authorize?, opts[:context])

    with {:ok, instance} <- Instance.get_by_id(instance_id, read_opts),
         {:ok, domain} <- AccessDomain.get_by_id(access_domain_id, read_opts),
         :ok <- ensure_addable(instance, domain),
         {:ok, hostname} <- mint(instance, domain, label),
         :ok <- apply_edge(instance, hostname, read_opts) do
      RenderAccessDNS.call()
      {:ok, hostname}
    end
  end

  # Each guard its own reason: the domain's ownership is a tenancy
  # boundary, the kind keeps the platform address single, and the state
  # is verify-by-issuance's honest gate.
  defp ensure_addable(instance, %AccessDomain{} = domain) do
    cond do
      domain.organization_id != instance.organization_id ->
        {:error, :different_organization}

      domain.kind != :custom ->
        {:error, :not_custom}

      domain.state != :verified ->
        {:error, :not_verified}

      true ->
        :ok
    end
  end

  # authorize?: false — the actor's hand was checked by the reads above
  # (the AccessDomain remove verbs' stance). The unique
  # (access_domain_id, label) identity catches a racing double-mint
  # loudly.
  defp mint(instance, domain, label) do
    InstanceHostname.mint(
      %{instance_id: instance.id, access_domain_id: domain.id, label: label},
      authorize?: false
    )
  end

  # A public instance holds no access edge (SetExposure's private arm
  # mints it later), even when a stale AccessRoute row survives the
  # public flip. Record the row; do not re-mint the private arm.
  defp apply_edge(%{exposure: :private} = instance, hostname, read_opts) do
    case AccessRoute.get_by_instance(instance.id, read_opts) do
      {:ok, route} ->
        gateway = Ash.load!(route, :gateway, read_opts).gateway
        apply_for_status(instance, hostname, gateway)

      {:error, error} ->
        if route_missing?(error) do
          :ok
        else
          unwind(instance, hostname, nil, error)
        end
    end
  end

  # An unattached or public instance has nothing to route: the row is
  # recorded and serves nothing until the pairing + private posture land
  # (the page copy says so).
  defp apply_edge(_instance, _hostname, _read_opts), do: :ok

  defp apply_for_status(instance, hostname, gateway) do
    case InstanceK8s.kubeconfig_for(instance) do
      {:ok, kubeconfig} ->
        case EdgeRoutes.apply_access_for_status(kubeconfig, gateway, instance) do
          :ok -> :ok
          {:error, reason} -> unwind(instance, hostname, kubeconfig, reason)
        end

      {:error, reason} ->
        unwind(instance, hostname, nil, reason)
    end
  end

  # The row must not stand when its edge failed, but it also must not
  # vanish while a route it minted still answers — that orphan would be
  # unsweepable (a re-mint gets a new row id, hence a new route name).
  # Destroy only after the route cleanup succeeds; on a cleanup failure
  # keep the row and return the cleanup error, so a later remove (which
  # deletes routes first) converges from the same record.
  defp unwind(instance, hostname, kubeconfig, reason) do
    case remove_routes(kubeconfig, instance, hostname) do
      :ok ->
        _destroyed = InstanceHostname.destroy(hostname, authorize?: false)
        {:error, reason}

      {:error, cleanup_error} ->
        {:error, cleanup_error}
    end
  end

  defp remove_routes(nil, _instance, _hostname), do: :ok

  defp remove_routes(kubeconfig, instance, hostname) do
    EdgeRoutes.apply_access_none_for_hostname(kubeconfig, instance, hostname)
  end

  defp route_missing?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{resource: AccessRoute}, &1))
  end

  defp route_missing?(_other), do: false

  # A nil context must not ride the Ash options as `context: nil`; a
  # real action context propagates (nested calls see the request).
  defp read_opts(actor, authorize?, nil), do: [actor: actor, authorize?: authorize?]

  defp read_opts(actor, authorize?, context) do
    [actor: actor, authorize?: authorize?, context: context]
  end
end
