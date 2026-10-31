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
  literal in its Secret), and doing it first means the restart that
  follows mounts the corrected config. Both writes fail the action — a
  row that says "reconnecting" over an unwritten Secret or an
  unregenerated config would be a lie the panel shows.
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.AccessProvider

  require Logger

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    auth_key = Ash.Changeset.get_argument(changeset, :auth_key)

    Ash.Changeset.before_action(changeset, fn changeset ->
      gateway = changeset.data

      with :ok <- maybe_refresh_domain(gateway, changeset),
           :ok <- AccessProvider.impl_for(gateway).update_credential(gateway, auth_key) do
        changeset
        |> Ash.Changeset.force_change_attribute(:state, :provisioning)
        |> Ash.Changeset.force_change_attribute(:status_message, "Reconnecting access")
        |> Ash.Changeset.force_change_attribute(:needs_attention_since, nil)
      else
        {:error, reason} ->
          Logger.error(
            "Access gateway #{changeset.data.id} credential update failed: #{inspect(reason)}"
          )

          Ash.Changeset.add_error(changeset,
            message: "Couldn't update the access key — try again"
          )
      end
    end)
  end

  # The serve rewrite runs only when the suffix actually moved: the
  # ordinary re-paste (same domain) must not depend on the cluster's
  # serve Secret being writable for the KEY recovery to land. The
  # struct passed in carries the incoming domain, so the regenerated
  # config renders the FQDN the owner just typed, not the stored one.
  defp maybe_refresh_domain(gateway, changeset) do
    domain = Ash.Changeset.get_attribute(changeset, :tailnet_domain)

    if domain != gateway.tailnet_domain do
      case AccessProvider.impl_for(gateway).refresh_routes(%{gateway | tailnet_domain: domain}) do
        {:ok, _serve_config} -> :ok
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end
end
