defmodule FluxVale.Infrastructure.Operations.RemoveAccessDomain do
  @moduledoc """
  Removes a custom access domain (ADR-0040 S1): safe-deletes the
  Certificate (404 tolerated — the safe-delete stance used across
  teardowns: the goal is "gone", not "witnessed dying"), then destroys
  the row.

  Refuses while any `InstanceHostname` still references the domain —
  the org's default-platform hostnames included. That is the whole
  rule, deliberately simple and honest: the caller re-homes or deletes
  the hostnames first, and a removal never silently unroutes serving
  instances as a side effect (the hostname FK is `on_delete: :restrict`
  — the DB backstop to this guard, not a replacement for it). The
  `:platform` kind is refused before anything is touched (and again by
  the `:remove` action's own guard — the two entry points have
  different callers, and the platform row is load-bearing).

  Ownership is enforced by the authorized re-read (the Instance
  `:delete` stance): the actor passes in opts, the read filters to
  their org, and a non-member gets Forbidden before any cluster call.
  """

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Certificate
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.InstanceHostname

  @doc """
  `:ok` or `{:error, reason}` — `reason` being `:platform_kind |
  :hostnames_present | Forbidden | term()`. `opts` carry `actor:` /
  `authorize?:`.
  """
  @spec call(AccessDomain.t(), keyword()) :: :ok | {:error, term()}
  def call(%AccessDomain{} = domain, opts \\ []) do
    actor = opts[:actor]
    authorize? = Keyword.get(opts, :authorize?, true)

    with {:ok, domain} <- AccessDomain.get_by_id(domain.id, actor: actor, authorize?: authorize?),
         :ok <- ensure_custom(domain),
         :ok <- ensure_no_hostnames(domain) do
      delete_certificate_then_row(domain, actor, authorize?)
    end
  end

  defp ensure_custom(%AccessDomain{kind: :custom}), do: :ok
  defp ensure_custom(%AccessDomain{kind: :platform}), do: {:error, :platform_kind}

  # The write concern is the caller's (the authorized read above already
  # proved membership), so the guard itself reads authorize?: false.
  defp ensure_no_hostnames(domain) do
    case InstanceHostname.list_for_domain(domain.id, authorize?: false) do
      {:ok, []} -> :ok
      {:ok, _hostnames} -> {:error, :hostnames_present}
      # coveralls-ignore-next-line - defensive: DB read failure, not simulatable under the sandbox
      {:error, _reason} = error -> error
    end
  end

  defp delete_certificate_then_row(domain, actor, authorize?) do
    with :ok <- safe_delete_certificate(domain) do
      case AccessDomain.remove(domain, actor: actor, authorize?: authorize?) do
        :ok -> :ok
        # coveralls-ignore-next-line - defensive: the row passed the authorized read above; a failure here is a DB fault
        {:error, _reason} = error -> error
      end
    end
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
