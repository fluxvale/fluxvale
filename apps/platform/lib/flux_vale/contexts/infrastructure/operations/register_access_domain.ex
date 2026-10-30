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

  The Certificate (and the Secret its wildcard lands in) is named by
  `AccessDomain.certificate_name/1` — the short-random-tail discipline.
  """

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Certificate
  alias FluxVale.Infrastructure.AccessDomain

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

    spec = %{
      domain: "*.#{domain.domain}",
      secret_name: AccessDomain.certificate_name(domain),
      issuer: Keyword.fetch!(config, :issuer)
    }

    with {:ok, kubeconfig} <- K8s.kubeconfig(),
         {:ok, _body} <-
           Certificate.create(
             kubeconfig,
             Keyword.fetch!(config, :certificate_namespace),
             AccessDomain.certificate_name(domain),
             spec
           ) do
      :ok
    end
  end
end
