defmodule FluxVale.Infrastructure.AccessGateway.CreateStoresApiToken do
  @moduledoc """
  The one-paste enable's token intake (#836) — the create twin of
  `SetApiToken`: when the create carries a Tailscale API credential, the
  provider writes the api-credential Secret and the row is born carrying
  the ref plus the rotation stamp.

  **Order is the recovery property** (the `SetApiToken` stance): the
  Secret first, the ref second — the ref columns commit with the row,
  only after the Secret landed.

  **No claim sweep here** (plan R2): the node does not exist yet, so
  there is nothing to claim with. Domains verified before the gateway
  existed converge through the observer's claim limb — the
  today-guarantee a token save must keep (#837 review).

  **Exactly one credential, three ways** (#836 lane B): an auth key, an
  API token, or the OAuth client pair (both halves) — validated before
  any write. Both-absent, any two shapes together, and a lone pair half
  are field-scoped refusals — refusing ambiguity is cheaper and more
  honest than a silent precedence rule (plan R2).

  **The owner fence is the CREDENTIAL's, not the row's** (#760
  precedent): the create policy stays member+funded+paid (a member
  enabling with their own pasted key is unchanged), and this change
  re-fences the authorize?-free seam exactly like
  `SetApiToken.ensure_org_owner` whenever a token or pair rides the
  create.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.Infrastructure.AccessProvider

  require Logger

  # The lane-B sentences: a lone pair half wants its sibling; a pair
  # beside any other credential is ambiguity, refused (plan R2's
  # posture — never a silent precedence rule).
  @pair_sentence "Save the client id and secret together"
  @mixed_sentence "Paste one credential only — the client pair or an API token or an auth key"

  @impl Ash.Resource.Change
  def change(changeset, _opts, context) do
    case intake(changeset) do
      {:ok, credential} ->
        changeset
        |> Ash.Changeset.before_action(fn changeset ->
          store_credential(changeset, context.actor, credential)
        end)
        |> Ash.Changeset.after_transaction(fn changeset, result ->
          cleanup_orphaned_secret(changeset, result)
        end)

      # The auth key alone: the pasted fallback, untouched by this
      # change (ProvisionCluster carries the key to the provider).
      :paste_path ->
        changeset

      {:refuse, field, message} ->
        refuse(changeset, field, message)
    end
  end

  # The three-way exactly-one-of (#836 lane B): auth_key | api_token |
  # client pair. The clauses ARE the rules, in priority order: a
  # complete pair beside any other credential is ambiguity (plan R2 —
  # never a silent precedence rule); the pair alone stores; the #853
  # both-tokens refusal verbatim; a lone pair half wants its sibling;
  # nothing at all is refused on the auth key; then the two single-
  # credential paths (the token stores, the pasted key rides as today).
  defp intake(changeset) do
    pasted = {
      trimmed(changeset, :auth_key),
      trimmed(changeset, :api_token),
      trimmed(changeset, :ts_client_id),
      trimmed(changeset, :ts_client_secret)
    }

    one_credential(pasted)
  end

  defp one_credential({key, token, client_id, client_secret})
       when is_binary(client_id) and is_binary(client_secret) and
              not (is_nil(key) and is_nil(token)) do
    {:refuse, :ts_client_id, @mixed_sentence}
  end

  defp one_credential({_key, _token, client_id, client_secret})
       when is_binary(client_id) and is_binary(client_secret) do
    {:ok, {:pair, client_id, client_secret}}
  end

  defp one_credential({key, token, _id, _secret}) when is_binary(key) and is_binary(token),
    do: {:refuse, :api_token, "Paste one or the other, not both"}

  # The id alone — its secret half is missing.
  defp one_credential({_key, _token, client_id, _secret}) when is_binary(client_id),
    do: {:refuse, :ts_client_secret, @pair_sentence}

  # The secret alone — its id half is missing.
  defp one_credential({_key, _token, _id, client_secret}) when is_binary(client_secret),
    do: {:refuse, :ts_client_id, @pair_sentence}

  defp one_credential({nil, nil, nil, nil}),
    do: {:refuse, :auth_key, "Paste an auth key or an API token to enable private access"}

  defp one_credential({_key, token, _id, _secret}) when is_binary(token),
    do: {:ok, {:console, token}}

  # The auth key alone: the pasted fallback, untouched by this change
  # (ProvisionCluster carries the key to the provider).
  defp one_credential({_key, _token, _id, _secret}), do: :paste_path

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (cluster I/O in the hook)
  def atomic?, do: false

  # The Secret written in before_action OUTLIVES a rolled-back insert —
  # external I/O is not unwound by the DB transaction (#853 hostile
  # review). The likeliest trigger is the unique_organization identity
  # (a double-submitted enable form); ProvisionCluster's cleanup never
  # runs in that window (its after_action follows a successful insert),
  # and the orphan would be permanent — the name derives from the dead
  # attempt's uuid, so no later create or teardown ever finds it. The
  # P1-1 rule ("no orphaned API key, from EVERY exit") closes it here:
  # best-effort delete on any error result, 404-tolerant and idempotent
  # with ProvisionCluster's own mint-failure cleanup (which also fires
  # on the paths where it can — a double call is harmless).
  defp cleanup_orphaned_secret(changeset, {:error, _reason} = result) do
    gateway = row_shape(changeset)

    _cleaned = AccessProvider.impl_for(gateway).cleanup_failed_provision(gateway)
    result
  end

  defp cleanup_orphaned_secret(_changeset, result), do: result

  defp store_credential(changeset, actor, credential) do
    gateway = row_shape(changeset)

    if actor && ActorIsOrganizationOwner.owner?(actor, %Organization{id: gateway.organization_id}) do
      case write_credential(gateway, credential) do
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

          {field, message} = store_failure_copy(credential)

          Ash.Changeset.add_error(
            changeset,
            InvalidArgument.exception(field: field, message: message)
          )
      end
    else
      Ash.Changeset.add_error(
        changeset,
        InvalidArgument.exception(
          field: fence_field(credential),
          message: "Only an organization owner can store the Tailscale API token"
        )
      )
    end
  end

  # The console arm rides the provider's token writer; the pair arm the
  # client-pair writer — same Secret, one shape per write (SSA).
  defp write_credential(gateway, {:console, token}) do
    AccessProvider.impl_for(gateway).write_api_credential(gateway, token)
  end

  defp write_credential(gateway, {:pair, client_id, client_secret}) do
    AccessProvider.impl_for(gateway).write_client_credential(gateway, client_id, client_secret)
  end

  # The store-failure and fence fields name the shape's leading input.
  defp store_failure_copy({:console, _token}),
    do: {:api_token, "we couldn't store the token — try again"}

  defp store_failure_copy({:pair, _id, _secret}),
    do: {:ts_client_secret, "we couldn't store the credential — try again"}

  # The fence error lands on the shape's leading input: the token arm
  # keeps the #760 field pin, the pair arm names the client id.
  defp fence_field({:console, _token}), do: :api_token
  defp fence_field({:pair, _id, _secret}), do: :ts_client_id

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

  defp trimmed(changeset, key) do
    case Ash.Changeset.get_argument(changeset, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _absent ->
        nil
    end
  end

  # add_error RETURNS the modified changeset — refusing means returning
  # it, not the original.
  defp refuse(changeset, field, message) do
    Ash.Changeset.add_error(
      changeset,
      InvalidArgument.exception(field: field, message: message)
    )
  end

  # Status codes and atoms only — never the provider's message or its
  # request body (the Secret carries the credential).
  defp reason_tag(%{status_code: code, reason: reason}),
    do: "http=#{inspect(code)} reason=#{inspect(reason)}"

  defp reason_tag(reason) when is_atom(reason), do: inspect(reason)
  defp reason_tag(_other), do: "unexpected"
end
