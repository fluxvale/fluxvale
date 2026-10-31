defmodule FluxVale.Infrastructure.Operations.RemoveAccessDomain do
  @moduledoc """
  Removes a custom access domain (ADR-0040 S1). The order is the
  safety property: **the row goes first** — its `instance_hostnames`
  FK is `on_delete: :restrict`, so Postgres itself refuses while any
  hostname still references the domain (the guard IS the constraint;
  there is no pre-check read to race a hostname mint) — and only once
  the row is gone is the Certificate safe-deleted (404 tolerated, the
  safe-delete stance used across teardowns). Never the reverse: live
  TLS state must not be deleted while the row still stands.

  The reverse residue is accepted: if the Certificate delete fails
  after the row is gone, an orphaned wildcard object can survive — it
  references a domain nobody holds a row for, and S3's API-client lane
  owns a namespace sweep.

  The `:platform` kind is refused before anything is touched (and again
  by the `:remove` action's own guard — the two entry points have
  different callers, and the platform row is load-bearing).

  **The unclaim limb (ADR-0040 S3):** before the destroy, the domain is
  un-claimed on the org's gateway if the gateway holds it — split-DNS
  route and subnet route revert, the gateway's `dns_claims` loses the
  entry. A failure FAILS the remove (the row stands, the owner retries):
  destroying first would strand tailnet state no row records anymore —
  the dangling-route shape nothing can converge. Membership was already
  proven by the authorized read above, so the limb runs system-side
  (authorize?: false).

  Ownership is enforced by the authorized re-read (the Instance
  `:delete` stance): the actor passes in opts, the read filters to
  their org, and a non-member gets Forbidden before any cluster call.
  """

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Certificate
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider

  @doc """
  `:ok` or `{:error, reason}` — `reason` being `:platform_kind |
  :hostnames_present | {:unclaim_failed, term()} | Forbidden | term()`.
  `opts` carry `actor:` / `authorize?:`.
  """
  @spec call(AccessDomain.t(), keyword()) :: :ok | {:error, term()}
  def call(%AccessDomain{} = domain, opts \\ []) do
    actor = opts[:actor]
    authorize? = Keyword.get(opts, :authorize?, true)

    with {:ok, domain} <- AccessDomain.get_by_id(domain.id, actor: actor, authorize?: authorize?),
         :ok <- ensure_custom(domain),
         :ok <- unclaim_tailnet_state(domain),
         :ok <- destroy_row(domain, actor, authorize?) do
      safe_delete_certificate(domain)
    end
  end

  defp ensure_custom(%AccessDomain{kind: :custom}), do: :ok
  defp ensure_custom(%AccessDomain{kind: :platform}), do: {:error, :platform_kind}

  # ------------------------------------------------------------------
  # The unclaim limb (ADR-0040 S3) — before the destroy, see moduledoc
  # ------------------------------------------------------------------

  defp unclaim_tailnet_state(domain) do
    found = AccessGateway.get_for_organization(domain.organization_id, authorize?: false)

    case found do
      {:ok, %AccessGateway{} = gateway} -> unclaim_on(gateway, domain)
      # No gateway — no claims anywhere; nothing to un-claim.
      {:error, _no_gateway} -> :ok
    end
  end

  defp unclaim_on(gateway, domain) do
    if Map.has_key?(gateway.dns_claims || %{}, domain.domain) do
      case unclaim_limb(gateway, domain) do
        :ok -> :ok
        # The remove FAILS (row stands, retry converges) — never a
        # dangling tailnet route no row records anymore.
        {:error, reason} -> {:error, {:unclaim_failed, reason}}
      end
    else
      :ok
    end
  end

  defp unclaim_limb(gateway, domain) do
    with :ok <- AccessProvider.impl_for(gateway).unclaim_domain(gateway, domain.domain),
         claims = Map.delete(gateway.dns_claims || %{}, domain.domain),
         {:ok, _row} <-
           AccessGateway.update_claims(gateway, %{dns_claims: claims}, authorize?: false) do
      :ok
    end
  end

  # The row's own FK is the hostname guard: a destroy with live
  # hostnames fails at the constraint (a hostname minted between the
  # authorized read and this destroy loses here — the race a pre-check
  # read could not close). Mapped to the guard's error shape so callers
  # see one reason.
  defp destroy_row(domain, actor, authorize?) do
    case AccessDomain.remove(domain, actor: actor, authorize?: authorize?) do
      :ok -> :ok
      {:error, error} -> map_destroy_error(error)
    end
  end

  defp map_destroy_error(error) do
    if hostname_restrict?(error) do
      {:error, :hostnames_present}
    else
      {:error, error}
    end
  end

  # The restrict constraint the reference declares on
  # instance_hostnames.access_domain_id — matched on the constraint
  # name, the one stable identity Postgres reports through every error
  # wrapper.
  @restrict_constraint "instance_hostnames_access_domain_id_fkey"

  defp hostname_restrict?(error) do
    error
    |> inspect()
    |> String.contains?(@restrict_constraint)
  end

  defp safe_delete_certificate(domain) do
    config = Application.fetch_env!(:flux_vale, :access_domains)

    with {:ok, kubeconfig} <- K8s.kubeconfig() do
      case Certificate.delete(
             kubeconfig,
             Keyword.fetch!(config, :certificate_namespace),
             AccessDomain.certificate_name(domain)
           ) do
        :ok -> :ok
        # Already gone (a prior attempt died mid-removal, or the object
        # was never landed): "gone" is the goal.
        {:error, %Error{reason: :not_found}} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end
end
