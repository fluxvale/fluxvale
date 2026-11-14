defmodule FluxVale.Infrastructure.Operations.SetAccessApiToken do
  @moduledoc """
  The API-token intake's code seam (#760, ADR-0040 §5, Am. 3): the
  owner's four-scope token into the gateway's api-credential Secret,
  and nothing recorded but the Secret's ref and the rotation stamp.

  The surface is the gateway's `:set_api_token` action — the Access
  panel's token card and `PATCH /api/v1/access-gateways/:id/api-token`.
  This module keeps the owner fence a policy cannot apply to an
  actorless call, and the `:ok | {:error, reason}` contract tests and
  operators use.

  The token goes IN and never comes out: the action's argument is
  sensitive (PaperTrail stores `REDACTED`), there is no read-back seam,
  and the return never carries it.
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.Infrastructure.AccessGateway

  @doc """
  `:ok` or `{:error, reason}` — `reason` being `:not_org_owner`, the
  Secret write's reason, or the row-write failure. The return is never
  the token.
  """
  @spec call(AccessGateway.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def call(%AccessGateway{} = gateway, token, opts \\ []) when is_binary(token) do
    actor = opts[:actor]

    with :ok <- ensure_org_owner(gateway, actor) do
      # The fence above already ran; authorize?: false keeps the policy
      # from re-reading and preserves the :not_org_owner shape.
      case AccessGateway.set_api_token(gateway, %{api_token: token},
             actor: actor,
             authorize?: false
           ) do
        {:ok, _row} -> :ok
        {:error, reason} -> {:error, unwrap(reason)}
      end
    end
  end

  # The crown is the owner's (ADR-0040 §12): a tailnet-level credential
  # outranks anything a plain member can touch, and an actorless call
  # has no owner to vouch for it.
  defp ensure_org_owner(_gateway, nil), do: {:error, :not_org_owner}

  defp ensure_org_owner(gateway, actor) do
    if ActorIsOrganizationOwner.owner?(actor, %Organization{id: gateway.organization_id}) do
      :ok
    else
      {:error, :not_org_owner}
    end
  end

  # The change keeps the provider's raw reason out of the error (a
  # struct there would crash the JSON:API encoder and could echo the
  # Secret); the op answers a stable tag for the write arm and passes
  # every other error class through untouched.
  defp unwrap(%Ash.Error.Invalid{errors: errors} = error) do
    if Enum.any?(
         errors,
         &match?(%Ash.Error.Changes.InvalidArgument{field: :api_token}, &1)
       ) do
      :api_token_write_failed
    else
      error
    end
  end

  # coveralls-ignore-start - the action only ever answers Invalid here;
  # this clause is the contract's floor (a non-Invalid error passes
  # through untouched) and no actor path can produce it.
  defp unwrap(error), do: error
  # coveralls-ignore-stop
end
