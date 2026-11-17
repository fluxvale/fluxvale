defmodule FluxVale.Infrastructure.AccessGateway.RepasteCredential do
  @moduledoc """
  The re-paste recovery (ADR-0039 §4): writes the new auth key to the
  gateway's Secret, restarts the pod so it rejoins under it, and moves
  the row from `:needs_attention` back to `:provisioning`.

  `:provisioning` rather than `:active` on purpose: the platform has not
  observed a join yet, and only `gateway_status` may claim `:active`
  (the observed-state rule — the row never asserts what the cluster has
  not shown). A wrong new key therefore lands the panel exactly where it
  was, with honest copy, instead of a false "Connected".

  A changed tailnet domain re-renders the serve config BEFORE the key
  write: the rewrite is the P1 repair path (a gateway provisioned
  before the column existed carries the broken `${TS_CERT_DOMAIN}`
  literal in its Secret), and doing it first means a restart that
  follows mounts the corrected config. Both the rewrite and the key
  write see the INCOMING domain — `changeset.data` is stale here (the
  row has not been written), and `:provisioning` re-pastes re-apply the
  whole gateway through the provider, so a stale struct would write the
  OLD FQDN back over the rewrite the same action just made.

  A key-write failure after a successful serve rewrite leaves the
  Secret on the new domain while the row keeps the old — cluster I/O
  cannot join the row's transaction. The divergence is bounded and
  converges: the retry re-runs both writes with the same inputs, the
  rewrite is idempotent, and until they meet the panel's address
  follows the row while the mounted config follows the Secret.

  #836's reconnect: an ABSENT key means the platform mints the
  enrollment key from the stored API token (`reconnect_minted/1` —
  supersede-revoke, mint, write, restart/re-apply, one provider
  operation). A `:suspended` row refuses BEFORE any provider call — a
  minted 1h key would sit unconsumed until a resume that may be days
  out (plan R2); the provider's own `reconnect_minted` refusal is the
  brace to this belt. A pasted key keeps today's semantics verbatim
  (including the suspended write-only arm — the user's key, their TTL),
  and the mint arm's failures surface through the R2 copy table
  (`AccessGateway.mint_error/1`), never as raw atoms.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider

  require Logger

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      # The struct the provider writes from — the row as this action is
      # about to see it, not the stale pre-write struct. Every provider
      # limb below (the serve rewrite, the credential write, the
      # :provisioning re-apply that rewrites the config again) must
      # render the same FQDN the row will land with.
      stored_domain = changeset.data.tailnet_domain

      gateway = %{
        changeset.data
        | tailnet_domain: Ash.Changeset.get_attribute(changeset, :tailnet_domain)
      }

      # The keyless mint's parked-row refusal reads the COMMITTED state
      # (keyless_reconnect below) — a caller can hold a stale
      # :provisioning/:active row while the ladder suspends underneath.
      if pasted?(changeset) do
        reconnect(changeset, gateway, stored_domain, true)
      else
        keyless_reconnect(changeset, gateway, stored_domain)
      end
    end)
  end

  # The keyless arm's gate: re-read the committed row before ANY
  # provider call. A stale :provisioning struct whose row was suspended
  # underneath would otherwise dispatch the provider's re-apply path —
  # resurrecting the suspended pod at one replica with no funding check
  # (#853 review). The re-read serializes the decision with suspension
  # (the SetApiToken ensure_storable stance); a vanished row refuses
  # like every other gone-row seam.
  defp keyless_reconnect(changeset, gateway, stored_domain) do
    case committed_gatekeeper(gateway) do
      {:ok, %{state: committed_state}} ->
        reconnect(changeset, %{gateway | state: committed_state}, stored_domain, false)

      {:error, state} when state in [:suspended, :destroying] ->
        resume_first(changeset)

      {:error, :gone} ->
        Ash.Changeset.add_error(
          changeset,
          InvalidArgument.exception(field: :id, message: "this gateway no longer exists")
        )
    end
  end

  defp resume_first(changeset) do
    Ash.Changeset.add_error(
      changeset,
      InvalidArgument.exception(
        field: :auth_key,
        message: "Resume the gateway first, then reconnect"
      )
    )
  end

  # The committed row's state — the decision input for the keyless mint
  # (a vanished row refuses; the struct's own state may be stale).
  defp committed_gatekeeper(%AccessGateway{} = gateway) do
    case AccessGateway.get_by_id(gateway.id, authorize?: false) do
      {:ok, %AccessGateway{state: state}} when state in [:suspended, :destroying] ->
        {:error, state}

      {:ok, %AccessGateway{state: state}} ->
        {:ok, %{state: state}}

      {:error, _gone} ->
        {:error, :gone}
    end
  end

  # The domain refresh limb is untouched and still runs first in both
  # arms; the credential limb dispatches on the pasted/mint split.
  defp reconnect(changeset, gateway, stored_domain, true) do
    auth_key = Ash.Changeset.get_argument(changeset, :auth_key)

    with :ok <- maybe_refresh_domain(gateway, stored_domain),
         :ok <- AccessProvider.impl_for(gateway).update_credential(gateway, auth_key) do
      reconnecting(changeset)
    else
      {:error, reason} ->
        Logger.error(
          "Access gateway #{changeset.data.id} credential update failed: #{inspect(reason)}"
        )

        Ash.Changeset.add_error(changeset, message: "Couldn't update the access key. Try again")
    end
  end

  defp reconnect(changeset, gateway, stored_domain, false) do
    with :ok <- maybe_refresh_domain(gateway, stored_domain),
         :ok <- AccessProvider.impl_for(gateway).reconnect_minted(gateway) do
      reconnecting(changeset)
    else
      {:error, reason} ->
        Logger.error(
          "Access gateway #{changeset.data.id} reconnect mint failed: #{inspect(reason)}"
        )

        Ash.Changeset.add_error(
          changeset,
          InvalidArgument.exception(
            field: :auth_key,
            message: AccessGateway.mint_error(reason)
          )
        )
    end
  end

  defp reconnecting(changeset) do
    changeset
    |> Ash.Changeset.force_change_attribute(:state, :provisioning)
    |> Ash.Changeset.force_change_attribute(:status_message, "Reconnecting access")
    |> Ash.Changeset.force_change_attribute(:needs_attention_since, nil)
  end

  # Present means a real key: non-empty after trim — the same rule the
  # create's exactly-one-of validation applies, so the two actions can
  # never disagree about what "pasted" means.
  defp pasted?(changeset) do
    case Ash.Changeset.get_argument(changeset, :auth_key) do
      key when is_binary(key) -> String.trim(key) != ""
      _absent -> false
    end
  end

  # The serve rewrite runs only when the suffix actually moved: the
  # ordinary re-paste (same domain, or none — get_attribute falls back
  # to the stored value) must not depend on the cluster's serve Secret
  # being writable for the KEY recovery to land. The struct already
  # carries the incoming domain, so the regenerated config renders the
  # FQDN the owner just typed, not the stored one.
  defp maybe_refresh_domain(gateway, stored_domain) do
    if gateway.tailnet_domain != stored_domain do
      case AccessProvider.impl_for(gateway).refresh_routes(gateway) do
        {:ok, _serve_config} -> :ok
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end
end
