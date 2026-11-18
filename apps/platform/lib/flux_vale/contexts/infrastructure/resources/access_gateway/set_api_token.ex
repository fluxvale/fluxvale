defmodule FluxVale.Infrastructure.AccessGateway.SetApiToken do
  @moduledoc """
  Stores the org's Tailscale API credential (ADR-0040 §5, Am. 3) through
  the owner surface: the provider writes the api-credential Secret, the
  row keeps only its ref plus the rotation stamp, and the org's
  already-verified custom domains are claimed on the gateway before the
  request returns.

  **Two shapes, one per save** (#836 lane B): the console API token
  alone, or the OAuth client pair (`ts_client_id` + `ts_client_secret`,
  both halves — the secret half is the crown). A mix, a lone half, or an
  empty save is refused on the offending field before anything is
  written. The Secret holds whichever shape was saved — SSA replaces the
  data map, so the other shape's keys do not survive a re-save.

  **Write-only.** The token and the client secret are sensitive action
  arguments, never attributes: they reach the provider's Secret write
  and nothing else. No read-back path exists, no log line receives
  them, and the action's return never carries them — the auth-key
  posture (ADR-0039 §4). The client id is not a secret (it rides every
  OAuth client's public identity) and is kept in the clear.

  **The claim sweep is the S6 follow-up.** A domain can verify before
  the owner ever pastes a credential; without this sweep the credential
  would do nothing until the operator ran an IEx claim. Saving claims
  every domain the org has already verified (via the shared
  `ClaimUnclaimedDomains` operation, so the same sweep serves the
  verify-pass and attach events that follow in #756). Claims are
  external state: a refusal is logged and never rolled back into the
  write. The sweep's own audit writes carry the same owner. The sweep
  reads the credential through `with_access_token/2` (B1's wrapper), so
  a pair-stored row claims with the OAuth-derived token — no
  shape-specific code here.

  **The row is re-read before the Secret write.** A deleted row or a
  `:destroying` gateway refuses before any cluster call, so a teardown
  never leaves a live credential Secret behind.

  **Order is the recovery property.** The Secret first, the ref second:
  a ref write that fails after the Secret landed leaves the credential
  restorable — the retry upserts the same Secret name (SSA) and writes
  the ref again.

  **Synchronous by design.** A claim is a handful of tailnet API calls
  per domain, bounded by the org's verified domains; the request is the
  event, so a queued retry would only add a second place to look.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias Ash.Error.Changes.InvalidAttribute
  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider
  alias FluxVale.Infrastructure.Operations.ClaimUnclaimedDomains

  require Logger

  # The one refusal sentence (#836 lane B): names both shapes and
  # nothing else. A mix, a lone half, and an empty save all carry it —
  # the field pin is what varies (the offending input).
  @pair_sentence "Save the client id and secret together, or the API token alone"

  @impl Ash.Resource.Change
  def change(changeset, _opts, context) do
    gateway = changeset.data
    actor = context.actor

    case intake(changeset) do
      {:ok, credential} ->
        changeset
        |> Ash.Changeset.before_action(fn changeset ->
          store_credential(changeset, gateway, actor, credential)
        end)
        |> Ash.Changeset.after_transaction(fn _changeset, result ->
          sweep_and_reread(result, actor)
        end)

      {:refused, changeset} ->
        changeset
    end
  end

  # Exactly one credential shape per save (#836 lane B). The clauses
  # ARE the rules, in match order: the console token alone; the pair
  # alone (both halves); any pair material beside a token (the mix); a
  # lone half; an empty save. "Empty after trim = absent" — a
  # whitespace-only half is a missing half. Refusals land on the
  # offending field, before any provider call.
  defp intake(changeset) do
    pasted = {
      trimmed(changeset, :api_token),
      trimmed(changeset, :ts_client_id),
      trimmed(changeset, :ts_client_secret)
    }

    case one_shape(pasted) do
      {:ok, credential} ->
        {:ok, credential}

      {:refuse, field} ->
        {:refused, refuse(changeset, field)}
    end
  end

  defp one_shape({token, nil, nil}) when is_binary(token), do: {:ok, {:console, token}}

  defp one_shape({nil, client_id, client_secret})
       when is_binary(client_id) and is_binary(client_secret) do
    {:ok, {:pair, client_id, client_secret}}
  end

  # The mix arm: any pair material beside a token.
  defp one_shape({token, _pair_id, _pair_secret}) when is_binary(token),
    do: {:refuse, :ts_client_id}

  # The id alone — its secret half is missing.
  defp one_shape({nil, client_id, _pair_secret}) when is_binary(client_id),
    do: {:refuse, :ts_client_secret}

  # The secret alone — its id half is missing.
  defp one_shape({nil, _pair_id, client_secret}) when is_binary(client_secret),
    do: {:refuse, :ts_client_id}

  # Nothing pasted: an empty save is a refused save.
  defp one_shape({nil, nil, nil}), do: {:refuse, :api_token}

  # add_error RETURNS the modified changeset — refusing means handing
  # it back, not the original.
  defp refuse(changeset, field) do
    Ash.Changeset.add_error(
      changeset,
      InvalidArgument.exception(field: field, message: @pair_sentence)
    )
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

  # The sweep claims every already-verified domain; the actor rides
  # along so the claims' audit rows carry the owner. The pre-sweep row
  # cannot answer `claimed_domains` honestly — re-read so the action's
  # return (and the PATCH response) reflects the claims just written.
  defp sweep_and_reread({:ok, row}, actor) do
    _summary = ClaimUnclaimedDomains.call(row, actor: actor)
    {:ok, fresh_row(row)}
  end

  defp sweep_and_reread(other, _actor), do: other

  defp store_credential(changeset, gateway, actor, credential) do
    with :ok <- ensure_org_owner(gateway, actor),
         :ok <- ensure_storable(gateway),
         {:ok, %{api_token_secret_ref: ref}} <- write_credential(gateway, credential) do
      changeset
      |> Ash.Changeset.force_change_attribute(:api_token_secret_ref, ref)
      |> Ash.Changeset.force_change_attribute(:token_set_at, DateTime.utc_now())
    else
      {:error, :not_org_owner} ->
        Ash.Changeset.add_error(
          changeset,
          ArgumentError.exception("Only an organization owner can store the Tailscale API token")
        )

      {:error, :gone} ->
        # A JSON-safe error class: the API must answer 4xx, never a
        # serialization crash on a provider struct.
        Ash.Changeset.add_error(
          changeset,
          InvalidAttribute.exception(
            field: :id,
            message: "this gateway no longer exists"
          )
        )

      {:error, :destroying} ->
        Ash.Changeset.add_error(
          changeset,
          InvalidAttribute.exception(
            field: :state,
            message: "this gateway is being removed"
          )
        )

      {:error, reason} ->
        # The reason is logged as a safe tag only: provider errors can
        # echo the Secret they failed to write, so the raw struct never
        # reaches a log line or the error's wire-visible vars.
        Logger.warning(
          "Access gateway #{gateway.hostname}: the api-credential write failed " <>
            "(#{reason_tag(reason)})"
        )

        {field, message} = store_failure_copy(credential)

        Ash.Changeset.add_error(
          changeset,
          InvalidArgument.exception(field: field, message: message)
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

  # The store-failure field is the shape's crown half; the sentence is
  # the shared retry-honest one, worded for the shape.
  defp store_failure_copy({:console, _token}),
    do: {:api_token, "we couldn't store the token — try again"}

  defp store_failure_copy({:pair, _id, _secret}),
    do: {:ts_client_secret, "we couldn't store the credential — try again"}

  # The policy carries the same fence for requests through the action;
  # this covers the authorize?-free seam and the nil actor.
  defp ensure_org_owner(gateway, actor) do
    if actor && ActorIsOrganizationOwner.owner?(actor, %Organization{id: gateway.organization_id}) do
      :ok
    else
      {:error, :not_org_owner}
    end
  end

  # No cluster call for a row that is gone or being torn down: a
  # teardown deletes the gateway's Secrets, so a credential written
  # after it would be orphaned.
  defp ensure_storable(%{state: :destroying}), do: {:error, :destroying}

  defp ensure_storable(gateway) do
    case AccessGateway.get_by_id(gateway.id, authorize?: false) do
      {:ok, _row} -> :ok
      {:error, _gone} -> {:error, :gone}
    end
  end

  defp fresh_row(row) do
    case AccessGateway.get_by_id(row.id, authorize?: false) do
      {:ok, fresh} ->
        fresh

      # coveralls-ignore-start - the row was deleted between the commit
      # and this re-read: a race window only a concurrent teardown hits,
      # and the pre-sweep row is still an honest answer then.
      {:error, _gone} ->
        row
        # coveralls-ignore-stop
    end
  end

  # Status codes and atoms only — never the provider's message or its
  # request body (the Secret carries the credential).
  defp reason_tag(%{status_code: code, reason: reason}),
    do: "http=#{inspect(code)} reason=#{inspect(reason)}"

  defp reason_tag(reason) when is_atom(reason), do: inspect(reason)
  defp reason_tag(_other), do: "unexpected"
end
