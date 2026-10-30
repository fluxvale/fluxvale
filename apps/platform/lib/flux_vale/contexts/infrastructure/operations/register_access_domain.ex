defmodule FluxVale.Infrastructure.Operations.RegisterAccessDomain do
  @moduledoc """
  Registers the org's own domain (ADR-0040 S1): writes the `:pending`
  row and issues the verification Certificate — one transaction.

  Verify-by-issuance: control over `apps.customer.com` is proven by
  issuing `*.apps.customer.com` through the `_acme-challenge`
  delegation the owner set up. The Certificate object here is DNS-01
  (a ClusterIssuer named from config — the fleet side owns that
  issuer; this operation only names it); Let's Encrypt does the rest.
  The row claims `:pending` — never a posture the cluster has not
  reached. Only `Operations.VerifyAccessDomains`, reading the Ready
  condition, promotes to `:verified`.

  The cluster call rides the create's transaction via an after_action:
  a failure rolls the row back WITH it, so a failed registration is
  the owner's retry (the AccessGateway create discipline — there is no
  stranded half-registered row to sweep).

  **Accepted residue:** when issuance fails, this operation
  best-effort deletes the Certificate it may have just landed (one
  delete, 404 tolerated). If that delete fails too, an orphaned
  Certificate object can survive on the cluster — the row rolled back,
  so nothing references it, and a wildcard cert alone grants nothing.
  S3's API-client lane owns a namespace sweep for these.

  The Certificate (and the Secret its wildcard lands in) is named by
  `AccessDomain.certificate_spec/1` — the one owner of the identity,
  shared with the verify pass's reconcile limb.
  """

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Certificate
  alias FluxVale.Infrastructure.AccessDomain

  require Logger

  @doc """
  `{:ok, domain}` or `{:error, reason}` — `reason` being the
  changeset's validation errors or the cluster failure. `opts` carry
  `actor:` / `authorize?:` (never hard-coded — the panel passes the
  member; policies scope the row to their org).
  """
  @spec call(map(), keyword()) :: {:ok, AccessDomain.t()} | {:error, term()}
  def call(params, opts \\ []) do
    AccessDomain
    |> Ash.Changeset.for_create(
      :register,
      params,
      actor: opts[:actor],
      authorize?: Keyword.get(opts, :authorize?, true)
    )
    |> Ash.Changeset.after_action(fn _changeset, domain ->
      with :ok <- issue_certificate(domain) do
        {:ok, domain}
      end
    end)
    |> Ash.create()
  end

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
