defmodule FluxVale.Infrastructure.AccessGateway.CreateStoresApiToken do
  @moduledoc """
  The one-paste enable's token intake (#836) — the create twin of
  `SetApiToken`: when the create carries `api_token` (and no auth key),
  the provider writes the api-credential Secret and the row is born
  carrying the ref plus the rotation stamp.

  **Order is the recovery property** (the `SetApiToken` stance): the
  Secret first, the ref second — the ref columns commit with the row,
  only after the Secret landed.

  **No claim sweep here** (plan R2): the node does not exist yet, so
  there is nothing to claim with. Domains verified before the gateway
  existed converge through the observer's claim limb — the
  today-guarantee a token save must keep (#837 review).

  **Exactly one credential**, validated before any write: both absent
  and both present are field-scoped refusals — refusing ambiguity is
  cheaper and more honest than a silent precedence rule (plan R2).

  **The owner fence is the TOKEN's, not the row's** (#760 precedent):
  the create policy stays member+funded+paid (a member enabling with
  their own pasted key is unchanged), and this change re-fences the
  authorize?-free seam exactly like `SetApiToken.ensure_org_owner`.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.Infrastructure.AccessProvider

  require Logger

  @impl Ash.Resource.Change
  def change(changeset, _opts, context) do
    key? = pasted?(Ash.Changeset.get_argument(changeset, :auth_key))
    token = trimmed_token(changeset)

    cond do
      not key? and is_nil(token) ->
        Ash.Changeset.add_error(
          changeset,
          InvalidArgument.exception(
            field: :auth_key,
            message: "Paste an auth key or an API token to enable private access"
          )
        )

      key? and token != nil ->
        Ash.Changeset.add_error(
          changeset,
          InvalidArgument.exception(
            field: :api_token,
            message: "Paste one or the other, not both"
          )
        )

      token != nil ->
        # The Secret write rides the create's transaction (the
        # SetApiToken posture): it lands before the row does, so the ref
        # the row commits with is always backed by a written Secret.
        Ash.Changeset.before_action(changeset, fn changeset ->
          store_token(changeset, context.actor, token)
        end)

      true ->
        changeset
    end
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (cluster I/O in the hook)
  def atomic?, do: false

  defp store_token(changeset, actor, token) do
    gateway = row_shape(changeset)

    if actor && ActorIsOrganizationOwner.owner?(actor, %Organization{id: gateway.organization_id}) do
      case AccessProvider.impl_for(gateway).write_api_credential(gateway, token) do
        {:ok, %{api_token_secret_ref: ref}} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:api_token_secret_ref, ref)
          |> Ash.Changeset.force_change_attribute(:token_set_at, DateTime.utc_now())

        {:error, reason} ->
          # The reason is logged as a safe tag only: provider errors can
          # echo the Secret they failed to write, so the raw struct never
          # reaches a log line or the error's wire-visible vars.
          Logger.warning(
            "Access gateway #{gateway.id}: the api-credential write at create failed " <>
              "(#{reason_tag(reason)})"
          )

          Ash.Changeset.add_error(
            changeset,
            InvalidArgument.exception(
              field: :api_token,
              message: "we couldn't store the token — try again"
            )
          )
      end
    else
      Ash.Changeset.add_error(
        changeset,
        InvalidArgument.exception(
          field: :api_token,
          message: "Only an organization owner can store the Tailscale API token"
        )
      )
    end
  end

  # The struct the provider writes from: the Secret's name derives from
  # the row's id, whose lazy default is on the changeset by the time
  # before_action hooks run — so the Secret lands under the exact name
  # the row will carry as its ref.
  defp row_shape(changeset) do
    %{
      changeset.data
      | id: Ash.Changeset.get_attribute(changeset, :id),
        organization_id: Ash.Changeset.get_attribute(changeset, :organization_id),
        hostname: Ash.Changeset.get_attribute(changeset, :hostname)
    }
  end

  defp trimmed_token(changeset) do
    case Ash.Changeset.get_argument(changeset, :api_token) do
      token when is_binary(token) ->
        trimmed = String.trim(token)
        if trimmed == "", do: nil, else: trimmed

      _absent ->
        nil
    end
  end

  defp pasted?(value) when is_binary(value), do: String.trim(value) != ""
  defp pasted?(_absent), do: false

  # Status codes and atoms only — never the provider's message or its
  # request body (the Secret carries the token).
  defp reason_tag(%{status_code: code, reason: reason}),
    do: "http=#{inspect(code)} reason=#{inspect(reason)}"

  defp reason_tag(reason) when is_atom(reason), do: inspect(reason)
  defp reason_tag(_other), do: "unexpected"
end
