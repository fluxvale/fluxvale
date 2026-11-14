defmodule FluxVale.Infrastructure.AccessGateway.SetApiToken do
  @moduledoc """
  Stores the org's four-scope Tailscale API token (ADR-0040 §5, Am. 3)
  through the owner surface: the provider writes the api-credential
  Secret, the row keeps only its ref plus the rotation stamp, and the
  domains this org already verified are claimed on the gateway before
  the request returns.

  **One write, one audit row.** The ref and `token_set_at` land on this
  action's own changeset, so the PaperTrail version carries the owner
  and `REDACTED` for the `api_token` input (ADR-0048's sensitive-
  argument stance). The token itself never reaches Postgres, a log
  line, the action's return, or a JSON:API response — the auth-key
  posture (ADR-0039 §4).

  **The claim sweep is the S6 follow-up.** A domain can verify before
  the owner ever pastes a token; without this sweep the token would do
  nothing until the operator ran an IEx claim. Saving the token is the
  event that makes every already-verified domain resolvable at once.
  Claims are external state: a failure is logged and never rolled back
  into the token write (the token is good either way), and the panel's
  domain lines carry the honest claimed/unclaimed result.

  Order is the recovery property, inherited from
  `Operations.SetAccessApiToken`: the Secret first, the ref second. A
  ref write that fails after the Secret landed leaves the token
  restorable — the retry upserts the same Secret name (SSA) and writes
  the ref again.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessProvider
  alias FluxVale.Infrastructure.Operations.ClaimAccessDomain
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS

  require Ash.Query
  require Logger

  @impl Ash.Resource.Change
  def change(changeset, _opts, context) do
    token = Ash.Changeset.get_argument(changeset, :api_token)
    gateway = changeset.data
    actor = context.actor

    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      with :ok <- ensure_org_owner(gateway, actor),
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

        {:error, reason} ->
          # The provider's reason rides `vars` so the code seam can keep
          # its atom contract; the user-facing message stays plain and
          # never mentions the token.
          Ash.Changeset.add_error(
            changeset,
            InvalidArgument.exception(
              field: :api_token,
              message: "we couldn't store the token — try again",
              vars: [reason: reason]
            )
          )
      end
    end)
    |> Ash.Changeset.after_transaction(fn _changeset, result ->
      case result do
        {:ok, row} ->
          claim_verified_domains(row)
          {:ok, row}

        other ->
          other
      end
    end)
  end

  # The policy carries the same fence for requests that arrive through
  # the action (panel, API); this one covers the authorize?-free seam
  # and the nil actor, exactly as the old operation did.
  defp ensure_org_owner(gateway, actor) do
    if actor && ActorIsOrganizationOwner.owner?(actor, %Organization{id: gateway.organization_id}) do
      :ok
    else
      {:error, :not_org_owner}
    end
  end

  # Event-driven, never a tick loop: the domains verified BEFORE this
  # token existed get claimed now, and the verify pass claims the ones
  # that verify later. A gateway that is not serving yet refuses with
  # :gateway_not_serving — the attach/promotion events own that case.
  defp claim_verified_domains(gateway) do
    already = claimed_names(gateway)

    pending =
      AccessDomain
      |> Ash.Query.filter(
        kind == :custom and state == :verified and organization_id == ^gateway.organization_id
      )
      |> Ash.read!(authorize?: false)
      |> Enum.reject(&(&1.domain in already))

    claimed? =
      Enum.any?(pending, fn domain ->
        case ClaimAccessDomain.call(gateway, domain, authorize?: false, render: false) do
          {:ok, _gateway} ->
            true

          {:error, reason} ->
            Logger.info(
              "Access gateway #{gateway.hostname}: #{domain.domain} left unclaimed after the " <>
                "token write: #{inspect(reason)}"
            )

            false
        end
      end)

    if claimed?, do: RenderAccessDNS.call()
    :ok
  rescue
    # The token is committed by the time this runs; a sweep crash must
    # not turn a successful save into an error response.
    error ->
      Logger.error("Access gateway #{gateway.hostname}: claim sweep crashed: #{inspect(error)}")
      :ok
  end

  defp claimed_names(%{dns_claims: claims}) when is_map(claims) and not is_struct(claims),
    do: Map.keys(claims)

  defp claimed_names(_gateway), do: []
end
