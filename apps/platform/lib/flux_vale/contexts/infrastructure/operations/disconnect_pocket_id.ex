defmodule FluxVale.Infrastructure.Operations.DisconnectPocketId do
  @moduledoc """
  The wiring's teardown (#597 S5, §4.6): delete the PocketID client
  (best-effort — a refusal is VISIBLE but never blocks the platform
  side), strip the recipe's env keys from the row AND the running
  workload (the apply primitive, same scope — only the recipe's
  keys), and clear the wiring row. The app keeps its local login
  (verified per-app in #511: every recipe app has one) — the copy
  says so.

  Order: the client delete FIRST (while the wiring row still holds
  its ids and the held key still has a reason to exist), then the
  env strip (row + cluster, atomically on the platform side), then
  the row. A failed client delete does NOT abort the disconnect —
  the leftover client is harmless and visible in PocketID's admin
  (the D6 posture); the result carries the notice.

  Returns `{:ok, %{client_deleted: boolean(), wiring: nil}}` — the
  boolean is the card's honest copy ("the client remains in your
  Pocket ID — delete it there").
  """

  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.ApplyPocketIdEnv
  alias FluxVale.Infrastructure.Operations.UsePocketIdKey
  alias FluxVale.Infrastructure.PocketId.ApiClient
  alias FluxVale.Infrastructure.PocketIdCustody
  alias FluxVale.Infrastructure.PocketIdWiring
  alias FluxVale.Ops.FeatureFlags
  alias FluxVale.Repo

  require Ash.Query
  require Logger

  @doc """
  `{:ok, %{client_deleted: boolean()}}` or `{:error, reason}` — the
  same guard family as the wiring op (`:flag_disabled`, `:not_wired`,
  `:pocket_id_gone`, `:no_custody`); a refused CLIENT DELETE is not an
  error (best-effort, D6) but a refused ENV STRIP is (the platform
  side must actually land).
  """
  @spec disconnect(Instance.t(), keyword()) ::
          {:ok, %{client_deleted: boolean()}} | {:error, term()}
  def disconnect(%Instance{id: instance_id}, opts \\ []) do
    actor = opts[:actor]

    with :ok <- flag_guard(),
         {:ok, wiring} <- wiring(instance_id),
         {:ok, recipe, app_instance} <- recipe_for(instance_id),
         {:ok, pocket_id} <- pocket_id(wiring),
         {:ok, custody} <- custody(pocket_id),
         {:ok, key} <- UsePocketIdKey.call(custody, "client_delete", actor: actor) do
      client_deleted = client_delete(pocket_id, key, wiring)

      strip_and_clear(app_instance, recipe, wiring, client_deleted)
    end
    |> maybe_clear_gone_wiring(instance_id)
  end

  # The gone-PocketID shape (§6: the wiring outlives its IdP): there
  # is no client left that FluxVale can reach — the delete is
  # impossible, not refused. The strip + clear still happen (that is
  # the card's "Clear wiring" verb); the leftover client, if the
  # PocketID ever returns, is PocketID-admin-visible and deletable.
  defp maybe_clear_gone_wiring({:error, :pocket_id_gone}, instance_id) do
    with {:ok, wiring} <- wiring(instance_id),
         {:ok, recipe, app_instance} <- recipe_for(instance_id) do
      strip_and_clear(app_instance, recipe, wiring, false)
    end
  end

  defp maybe_clear_gone_wiring(result, _instance_id), do: result

  defp flag_guard do
    if FeatureFlags.enabled?(:pocketid_sso_wiring),
      do: :ok,
      else: {:error, :flag_disabled}
  end

  defp wiring(instance_id) do
    case PocketIdWiring.get_by_instance(instance_id, authorize?: false) do
      {:ok, wiring} -> {:ok, wiring}
      {:error, _none} -> {:error, :not_wired}
    end
  end

  defp pocket_id(wiring) do
    case Ash.get(Instance, wiring.pocket_id_instance_id, authorize?: false) do
      {:ok, pocket_id} -> {:ok, pocket_id}
      {:error, _gone} -> {:error, :pocket_id_gone}
    end
  end

  defp custody(pocket_id) do
    case PocketIdCustody.get_by_instance(pocket_id.id, authorize?: false) do
      {:ok, custody} -> {:ok, custody}
      {:error, _none} -> {:error, :no_custody}
    end
  end

  defp recipe_for(instance_id) do
    case Ash.get(Instance, instance_id, authorize?: false) do
      {:ok, app_instance} ->
        case Ash.load(app_instance, :app_version, authorize?: false) do
          {:ok, %{app_version: %{oidc_wiring: recipe}}} when not is_nil(recipe) ->
            {:ok, recipe, app_instance}

          {:ok, _no_recipe} ->
            {:error, :recipe_missing}
        end

      {:error, _gone} ->
        {:error, :not_wired}
    end
  end

  # Best-effort BY DESIGN (D6): a refused delete leaves a harmless,
  # visible client named `FluxVale · …` in PocketID's admin. The
  # disconnect proceeds — the notice rides the result.
  defp client_delete(pocket_id, key, wiring) do
    url = base_url(pocket_id)
    client_id = wiring.pocket_id_client_id

    case ApiClient.delete_client(url, key, client_id) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning(
          "PocketID client delete refused on disconnect (client " <>
            "#{wiring.pocket_id_client_id}): #{inspect(reason)} — it remains in PocketID, deletable there"
        )

        false
    end
  end

  # The strip's two surfaces, ordered for convergence: the WORKLOAD
  # first (the apply primitive — idempotent; a failure here leaves
  # wiring standing and the retry converges), then the ROW side in
  # ONE lock-protected transaction (env strip + wiring clear together
  # — a concurrent retrofit's record serializes on the same instance
  # row, so the clear never lands under a fresh wiring; and the clear
  # never precedes the workload it describes).
  defp strip_and_clear(app_instance, recipe, wiring, client_deleted) do
    recipe_keys =
      maybe_prepend(
        [recipe.issuer_env, recipe.client_id_env, recipe.client_secret_env],
        recipe.enabled_env
      )

    case apply_strip(app_instance, recipe_keys) do
      :ok ->
        clear_under_lock(app_instance, wiring, recipe_keys, client_deleted)

      {:error, _reason} = error ->
        error
    end
  end

  # The row side, one lock-protected transaction: env strip + wiring
  # clear together.
  defp clear_under_lock(app_instance, wiring, recipe_keys, client_deleted) do
    result =
      Repo.transaction(fn ->
        locked = lock_instance!(app_instance.id)
        stripped = Map.drop(locked.env_vars, recipe_keys)

        write =
          locked
          |> Ash.Changeset.for_update(:merge_pocket_id_env, %{env: stripped}, authorize?: false)
          |> Ash.update(return_notifications?: true)

        case write do
          {:ok, _env, notifications} ->
            PocketIdWiring.replace(wiring, authorize?: false)
            notifications

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, notifications} ->
        Ash.Notifier.notify(notifications)
        {:ok, %{client_deleted: client_deleted}}

      {:error, _reason} = error ->
        error
    end
  end

  # The strip's cluster leg: a deployed instance carries the removal
  # to the Secret + rollout (the app's own unset semantics — missing
  # keys are feature-off); a pre-deploy instance's row is the whole
  # truth until first deploy, nothing to reach.
  defp apply_strip(%Instance{namespace: nil}, _recipe_keys), do: :ok

  defp apply_strip(%Instance{} = app_instance, recipe_keys) do
    ApplyPocketIdEnv.apply_to_running(app_instance, %{}, remove_keys: recipe_keys)
  end

  defp maybe_prepend(keys, nil), do: keys
  defp maybe_prepend(keys, enabled_env), do: [enabled_env | keys]

  defp lock_instance!(instance_id) do
    Instance
    |> Ash.Query.filter(id == ^instance_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(authorize?: false)
  end

  defp base_url(%Instance{slug: slug}) do
    "https://#{slug}.#{Application.fetch_env!(:flux_vale, :instances_base_domain)}"
  end
end
