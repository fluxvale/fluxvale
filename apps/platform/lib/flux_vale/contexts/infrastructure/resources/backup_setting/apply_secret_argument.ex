defmodule FluxVale.Infrastructure.BackupSetting.ApplySecretArgument do
  @moduledoc """
  The JSON:API routes' write-only `:secret_access_key` argument (#482):
  a present, non-blank value (re)applies the namespace's `backup-config`
  Secret through `ConfigureBackups.apply_namespace_secret/3` — the
  operation's one secret path, never a second implementation. Absent or
  blank keeps the Secret untouched (the operation's `blank_to_nil`
  stance): a coordinates-only save must not wipe credentials.

  The apply rides `after_action` — only reached when the policies have
  authorized the write — and an error there fails the action, so a
  failed apply persists no row (the operation's "failure writes no
  row" order; the Secret still lands before the row becomes visible).
  The value never reaches the row, a response, or the logs (sensitive
  argument — Ash redacts it).
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.ConfigureBackups

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    secret = Ash.Changeset.get_argument(changeset, :secret_access_key)

    if is_nil(secret) or secret == "" do
      changeset
    else
      Ash.Changeset.after_action(changeset, &apply_secret/2)
    end
  end

  # authorize?: false is a precondition read, not a bypass: the row's
  # own policies already fenced this caller to this instance (create/
  # update authorize via `relates_to_actor_via([:instance, ...])`).
  # The read only fetches the namespace the Secret lands in.
  defp apply_secret(changeset, setting) do
    instance = Instance.get_by_id!(setting.instance_id, authorize?: false)
    secret = Ash.Changeset.get_argument(changeset, :secret_access_key)

    case ConfigureBackups.apply_namespace_secret(instance, changeset, %{secret_access_key: secret}) do
      {:ok, _kubeconfig} ->
        {:ok, setting}

      {:error, _reason} = error ->
        error
    end
  end
end
