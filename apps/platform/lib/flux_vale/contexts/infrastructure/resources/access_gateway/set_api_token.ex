defmodule FluxVale.Infrastructure.AccessGateway.SetApiToken do
  @moduledoc """
  Stores the org's four-scope Tailscale API token (ADR-0040 §5, Am. 3)
  through the owner surface: the provider writes the api-credential
  Secret, the row keeps only its ref plus the rotation stamp, and the
  org's already-verified custom domains are claimed on the gateway
  before the request returns.

  **Write-only.** The token is a sensitive action argument, never an
  attribute: it reaches the provider's Secret write and nothing else.
  No read-back path exists, no log line receives it, and the action's
  return never carries it — the auth-key posture (ADR-0039 §4).

  **The claim sweep is the S6 follow-up.** A domain can verify before
  the owner ever pastes a token; without this sweep the token would do
  nothing until the operator ran an IEx claim. Saving the token claims
  every domain the org has already verified (via the shared
  `ClaimUnclaimedDomains` operation, so the same sweep serves the
  verify-pass and attach events that follow in #756). Claims are
  external state: a refusal is logged and never rolled back into the
  token write. The sweep's own audit writes carry the same owner.

  **The row is re-read before the Secret write.** A deleted row or a
  `:destroying` gateway refuses before any cluster call, so a teardown
  never leaves a live token Secret behind.

  **Order is the recovery property.** The Secret first, the ref second:
  a ref write that fails after the Secret landed leaves the token
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

  @impl Ash.Resource.Change
  def change(changeset, _opts, context) do
    gateway = changeset.data
    actor = context.actor

    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      token =
        changeset
        |> Ash.Changeset.get_argument(:api_token)
        |> String.trim()

      with :ok <- ensure_org_owner(gateway, actor),
           :ok <- ensure_storable(gateway),
           {:ok, %{api_token_secret_ref: ref}} <-
             AccessProvider.impl_for(gateway).write_api_credential(gateway, token) do
        changeset
        |> Ash.Changeset.force_change_attribute(:api_token_secret_ref, ref)
        |> Ash.Changeset.force_change_attribute(:token_set_at, DateTime.utc_now())
      else
        {:error, :not_org_owner} ->
          Ash.Changeset.add_error(
            changeset,
            ArgumentError.exception(
              "Only an organization owner can store the Tailscale API token"
            )
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

          Ash.Changeset.add_error(
            changeset,
            InvalidArgument.exception(
              field: :api_token,
              message: "we couldn't store the token — try again"
            )
          )
      end
    end)
    |> Ash.Changeset.after_transaction(fn _changeset, result ->
      case result do
        {:ok, row} ->
          # The sweep claims every already-verified domain; the actor
          # rides along so the claims' audit rows carry the owner.
          _summary = ClaimUnclaimedDomains.call(row, actor: actor)

          # The pre-sweep row cannot answer `claimed_domains` honestly —
          # re-read so the action's return (and the PATCH response)
          # reflects the claims just written.
          {:ok, fresh_row(row)}

        other ->
          other
      end
    end)
  end

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
  # teardown deletes the gateway's Secrets, so a token written after it
  # would be orphaned.
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
  # request body (the Secret carries the token).
  defp reason_tag(%{status_code: code, reason: reason}),
    do: "http=#{inspect(code)} reason=#{inspect(reason)}"

  defp reason_tag(reason) when is_atom(reason), do: inspect(reason)
  defp reason_tag(_other), do: "unexpected"
end
