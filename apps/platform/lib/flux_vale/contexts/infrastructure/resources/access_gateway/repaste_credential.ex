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
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.AccessProvider

  require Logger

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    auth_key = Ash.Changeset.get_argument(changeset, :auth_key)

    Ash.Changeset.before_action(changeset, fn changeset ->
      # The provider write happens BEFORE the row write so a Secret
      # failure fails the action: a row that says "reconnecting" over an
      # unwritten key would be a lie the panel shows.
      case AccessProvider.impl_for(changeset.data).update_credential(changeset.data, auth_key) do
        :ok ->
          changeset
          |> Ash.Changeset.force_change_attribute(:state, :provisioning)
          |> Ash.Changeset.force_change_attribute(:status_message, "Reconnecting access")
          |> Ash.Changeset.force_change_attribute(:needs_attention_since, nil)

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
end
