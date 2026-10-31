defmodule FluxVale.Infrastructure.Operations.SetAccessApiToken do
  @moduledoc """
  Stores the org's Tailscale API token (ADR-0040 §5): writes the
  gateway's api-credential Secret, then records the Secret's ref on the
  row through the `:set_api_token_ref` funnel. This is the FIRST
  tailnet-level credential beyond a join key — dns + routes scopes — so
  it rides the authkey discipline exactly: password-shaped input, the
  token goes IN and never comes out (no reveal path, never logged).

  Order is the recovery property: the Secret first, the ref second. A
  ref write that fails after the Secret landed leaves the token
  restorable — the retry re-runs both limbs and the Secret write is an
  SSA upsert (no duplicate). The reverse order would strand a ref to a
  Secret that does not exist.

  The operation is the seam; the settings form is a later slice.
  Ownership is enforced by the authorized gateway read (the Instance
  `:delete` stance) — and the write is **owner-only** beyond that: this
  key is the crown (ADR-0040 §12 — with it FluxVale can rewrite the
  customer's whole tailnet DNS), so the org's `:member` role pasting a
  key is the blast radius nobody signed up for. The owner-only gate
  bites at team features; today every gateway org is single-owner, so
  the gate is the ADR's stance made code before the first team exists.
  """

  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider

  # The shared owner predicate (the ActorIsOrganizationOwner module) —
  # same answer as the org-rename policy check, so the notion cannot
  # fork. The gateway's org id rides a bare struct: the predicate only
  # resolves the membership.
  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorIsOrganizationOwner

  @doc """
  `:ok` or `{:error, reason}` — `reason` being Forbidden, `:not_org_owner`,
  the Secret write failure, or the ref-write failure. `opts` carry
  `actor:` / `authorize?:`.

  The return is never the token and the token is never accepted back
  from the row — there is no read-back at this seam.
  """
  @spec call(AccessGateway.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def call(%AccessGateway{} = gateway, token, opts \\ []) when is_binary(token) do
    actor = opts[:actor]
    store_token(gateway, token, actor, Keyword.get(opts, :authorize?, true))
  end

  defp store_token(gateway, token, actor, authorize?) do
    with {:ok, gateway} <-
           AccessGateway.get_by_id(gateway.id, actor: actor, authorize?: authorize?),
         :ok <- ensure_org_owner(gateway, actor),
         {:ok, %{api_token_secret_ref: ref}} <-
           AccessProvider.impl_for(gateway).write_api_credential(gateway, token) do
      record_ref(gateway, ref)
    end
  end

  # Mere membership is not enough for a tailnet-level credential
  # (§12): the `:member` role can read the gateway panel, and the key
  # it would paste here outranks anything else a member can touch.
  defp ensure_org_owner(_gateway, nil), do: {:error, :not_org_owner}

  defp ensure_org_owner(gateway, actor) do
    if ActorIsOrganizationOwner.owner?(actor, %Organization{id: gateway.organization_id}) do
      :ok
    else
      {:error, :not_org_owner}
    end
  end

  # The row stores the Secret's NAME (never the token) — the provider
  # owns the naming rule, the funnel owns the write. authorize?: false:
  # this operation's authorization already happened on the read above.
  defp record_ref(gateway, ref) do
    case AccessGateway.set_api_token_ref(gateway, %{api_token_secret_ref: ref}, authorize?: false) do
      {:ok, _row} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
