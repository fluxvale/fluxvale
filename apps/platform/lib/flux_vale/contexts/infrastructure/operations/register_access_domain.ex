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

  The cluster call rides the create's transaction — as the register
  action's own `AccessDomain.MintCertificate` change, so the panel
  operation and the API route share ONE mint. A failure rolls the row
  back with it: a failed registration is the owner's retry (the
  AccessGateway create discipline — there is no stranded
  half-registered row to sweep). The change module owns the
  transactional argument and the accepted Certificate residue.

  The Certificate (and the Secret its wildcard lands in) is named by
  `AccessDomain.certificate_spec/1` — the one owner of the identity,
  shared with the verify pass's reconcile limb.
  """

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
    |> Ash.create()
  end
end
