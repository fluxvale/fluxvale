defmodule FluxVale.Infrastructure.AccessDomain.MintCertificate do
  @moduledoc """
  The register action's cluster leg (ADR-0040 S1): issues the DNS-01
  wildcard Certificate INSIDE the create's transaction — the
  after_action's error return rolls the row back with it, so a failed
  registration is the owner's retry and no stranded half-registered
  row survives (the AccessGateway create discipline).

  Lives on the ACTION, not the panel operation, so every register
  entry point — `Operations.RegisterAccessDomain` and the API route —
  converges on one mint. Verify-by-issuance: the row claims `:pending`
  and nothing more; only the observer pass, reading the Ready
  condition, promotes. The Certificate identity is
  `AccessDomain.certificate_spec/1` — the one owner, shared with the
  verify pass's reconcile limb.

  **Accepted residue:** when issuance fails, this change best-effort
  deletes the Certificate it may have just landed (one delete, 404
  tolerated). If that delete fails too, an orphaned Certificate object
  can survive on the cluster — the row rolled back, so nothing
  references it, and a wildcard cert alone grants nothing. S3's
  API-client lane owns a namespace sweep for these.
  """

  use Ash.Resource.Change

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Certificate
  alias FluxVale.Infrastructure.AccessDomain

  require Logger

  # The resource references this change only as a DSL atom, so the two
  # may compile in either order — the parallel compiler can reach this
  # module first and warn on the derivations below. Same app, and the
  # resource is fully compiled before any register runs: the warning
  # would be noise; the gate compiles --warnings-as-errors.
  @compile {:no_warn_undefined, {AccessDomain, :certificate_name, 1}}

  @compile {:no_warn_undefined, {AccessDomain, :certificate_spec, 1}}

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    # The cluster call rides the create's transaction: an error return
    # here rolls the row back.
    Ash.Changeset.after_action(changeset, fn _changeset, domain ->
      with :ok <- issue_certificate(domain) do
        {:ok, domain}
      end
    end)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (cluster I/O in the hook)
  def atomic?, do: false

  # Inside the create's transaction: an error return rolls the row back.
  defp issue_certificate(domain) do
    config = Application.fetch_env!(:flux_vale, :access_domains)
    name = AccessDomain.certificate_name(domain)

    case K8s.kubeconfig() do
      {:ok, kubeconfig} ->
        case Certificate.create(
               kubeconfig,
               Keyword.fetch!(config, :certificate_namespace),
               name,
               AccessDomain.certificate_spec(domain)
             ) do
          {:ok, _body} ->
            :ok

          {:error, reason} ->
            cleanup_attempt(kubeconfig, config, domain, name)
            {:error, reason}
        end

      # No kubeconfig — nothing was applied, nothing to clean.
      {:error, _reason} = error ->
        error
    end
  end

  # Best-effort cleanup of the object this attempt may have half-landed
  # (an SSA timeout can leave it behind): one delete, 404 tolerated. If
  # the delete fails too, the residual Certificate is accepted and
  # logged (see the moduledoc's accepted-residue note).
  defp cleanup_attempt(kubeconfig, config, domain, name) do
    case Certificate.delete(
           kubeconfig,
           Keyword.fetch!(config, :certificate_namespace),
           name
         ) do
      :ok ->
        :ok

      {:error, %Error{reason: :not_found}} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Access domain #{domain.domain}: rollback Certificate delete failed " <>
            "(residual object accepted): #{inspect(reason)}"
        )

        :ok
    end
  end
end
