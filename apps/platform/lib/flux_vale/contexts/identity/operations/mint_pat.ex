defmodule FluxVale.Identity.Operations.MintPat do
  @moduledoc """
  Mints a scoped personal access token (#360, ADR-0019 Am. 1).

  The raw value (`fvpat_` + 43 url-safe chars) exists ONLY in the
  `{:ok, %{token: raw, pat: row}}` return — never logged, never
  stored; the row carries its SHA-256 hash alone. The create policy
  is the gate: a user mints for themselves, a platform admin for
  anyone (the developer settings page consumes this later).

  A derived mint (provenance carries `minted_parent_id`, #772) is
  additionally bounded by the resource's per-user live-token cap:
  overflow returns `{:error, :too_many_live_tokens}`.
  """

  alias FluxVale.Api
  alias FluxVale.Api.Scopes
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Identity.PersonalAccessToken.EnforceDerivedTokenCap

  require Logger

  @token_prefix "fvpat_"
  # Same lifetime the #23 JWT PAT carried — `expires_at` bounds the
  # worst case; revocation is the instant mechanism.
  @lifetime_seconds 365 * 24 * 60 * 60

  @doc """
  Mints a PAT for `params.user_id`.

  `params`: `%{user_id:, name:, scopes:}` (empty scopes allowed;
  optional `expires_at` overrides the 1-year default — a longer value
  is capped to it; optional `metadata` carries the mint provenance,
  #362's device-flow shape — system-written, never accepted from a
  policy-facing caller surface beyond this operation's argument).
  Returns
  `{:ok, %{token: raw_value, pat: %PersonalAccessToken{}}}` — the
  caller shows the value once (or never); there is no way to recover
  it later. Off-catalog or duplicate scopes are refused before
  anything is generated.
  """
  @spec call(map() | nil, map(), keyword()) ::
          {:ok, %{token: String.t(), pat: PersonalAccessToken.t()}} | {:error, term()}
  def call(actor, params, opts \\ []) do
    scopes = params[:scopes] || []

    with :ok <- Scopes.validate(scopes) do
      random =
        32
        |> :crypto.strong_rand_bytes()
        |> Base.url_encode64(padding: false)

      raw = @token_prefix <> random
      expires_at = expiry(params[:expires_at])
      create_opts = Keyword.put(opts, :actor, actor)

      changeset =
        PersonalAccessToken
        |> Ash.Changeset.new()
        # The digest of the generated value, via the action's private
        # argument — set by the system, never an accepted input (the
        # before-for_create pattern Ash itself prescribes).
        |> Ash.Changeset.set_argument(:token_hash, PersonalAccessToken.token_hash(raw))
        # The provenance record rides the same private-argument shape
        # (#362): set by the operation, never an accepted input.
        |> Ash.Changeset.set_argument(:metadata, params[:metadata] || %{})
        |> Ash.Changeset.for_create(
          :create,
          %{
            user_id: params[:user_id],
            name: params[:name],
            scopes: scopes,
            expires_at: expires_at
          },
          create_opts
        )

      case Ash.create(changeset) do
        {:ok, pat} ->
          # Audit the mint, never the token value (v1 posture).
          Logger.info(
            "PAT minted: user=#{pat.user_id} token=#{pat.id} scopes=#{Enum.join(pat.scopes, ",")}"
          )

          # The audit row names the OPERATOR (an admin minting for a
          # member differs from self-service); nil on the no-actor
          # operator path. Guarded — a failed row never fails a
          # minted token.
          Api.record_audit_event(%{
            kind: :mint,
            personal_access_token_id: pat.id,
            actor_id: actor && actor.id
          })

          {:ok, %{token: raw, pat: pat}}

        # The derived-token cap (#772) is a domain refusal, not a
        # system failure: classify it so the caller can answer with
        # the cap's own status, and pass every other create error
        # through unchanged.
        {:error, %Ash.Error.Invalid{errors: errors}} = refusal ->
          classify_refusal(refusal, EnforceDerivedTokenCap.refusal?(errors))

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp classify_refusal(_refusal, true), do: {:error, :too_many_live_tokens}
  defp classify_refusal(refusal, false), do: refusal

  # The override may shorten, never lengthen: the one-year bound is
  # the worst case the resource's moduledoc promises (the compromise
  # window a leak buys), so a far-future value is capped to it.
  defp expiry(nil), do: default_expiry()

  defp expiry(expires_at) do
    cap = default_expiry()

    if DateTime.after?(expires_at, cap), do: cap, else: expires_at
  end

  defp default_expiry do
    DateTime.add(DateTime.utc_now(), @lifetime_seconds, :second)
  end
end
