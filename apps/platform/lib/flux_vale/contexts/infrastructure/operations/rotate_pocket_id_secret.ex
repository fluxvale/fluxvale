defmodule FluxVale.Infrastructure.Operations.RotatePocketIdSecret do
  @moduledoc """
  The wiring's secret rotation (#597 S5, §4.6) — the zero-downtime
  sequence the plan's live transcript verified on PocketID v2.19.2:

  1. a SECOND active secret on the client (caller-supplied, platform
     generated — the old one stays usable);
  2. the new value applied to the running workload (the SSO-scoped
     env-update + rollout primitive — the only pods-motion moment);
  3. the OLD secret deleted — both sides are never invalid together.

  The wiring row's `secret_id` moves to the new secret (rotation's
  durable record). A failed step-3 leaves a harmless extra active
  secret in PocketID (visible, deletable there) and the rotation
  still COMPLETE — logged, answered `:ok`.

  Failure posture mirrors the wiring op (D3-adjacent): every refusal
  is a visible, retryable answer; a failed apply (step 2) leaves the
  OLD secret fully live — the rotation simply hasn't happened.
  """

  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.ApplyPocketIdEnv
  alias FluxVale.Infrastructure.Operations.UsePocketIdKey
  alias FluxVale.Infrastructure.PocketId.ApiClient
  alias FluxVale.Infrastructure.PocketIdCustody
  alias FluxVale.Infrastructure.PocketIdWiring
  alias FluxVale.Ops.FeatureFlags

  require Logger

  # v2.19.2's floor for a caller-supplied secret: ≥16 printable ASCII.
  @secret_bytes 32

  @doc """
  `{:ok, wiring}` (the row, `secret_id` now the new secret's) or
  `{:error, reason}` — `:flag_disabled`, `:not_wired`,
  `:not_deployed` (rotation is the running-workload verb; a
  not-yet-deployed wiring re-ships at its next deploy),
  `:pocket_id_gone`, `:recipe_missing`, `:no_custody`, the key-use
  refusals, or the apply primitive's own errors (old secret untouched
  in that case).
  """
  @spec rotate(PocketIdWiring.t(), keyword()) :: {:ok, PocketIdWiring.t()} | {:error, term()}
  def rotate(%PocketIdWiring{} = wiring, opts \\ []) do
    actor = opts[:actor]

    with :ok <- flag_guard(),
         {:ok, instance, pocket_id, recipe} <- context(wiring),
         {:ok, custody} <- custody(pocket_id),
         {:ok, key} <- UsePocketIdKey.call(custody, "client_rotate", actor: actor),
         new_secret = generated_secret(),
         url = base_url(pocket_id),
         client_id = wiring.pocket_id_client_id,
         {:ok, %{secret_id: new_secret_id}} <-
           ApiClient.create_secret(url, key, client_id, new_secret),
         :ok <- apply_new(instance, recipe, new_secret) do
      delete_old(pocket_id, key, wiring)
      move_secret_id(wiring, new_secret_id)
    end
  end

  defp flag_guard do
    if FeatureFlags.enabled?(:pocketid_sso_wiring),
      do: :ok,
      else: {:error, :flag_disabled}
  end

  # The rotation's context: the wiring's app instance (deployed — the
  # rollout is the point), its PocketID (the API base URL), and the
  # recipe (the env name the new secret lands under).
  defp context(wiring) do
    with {:ok, instance} <- load_instance(wiring),
         {:ok, pocket_id} <- load_pocket_id(wiring),
         {:ok, recipe} <- recipe(instance) do
      {:ok, instance, pocket_id, recipe}
    end
  end

  defp load_instance(wiring) do
    case Ash.get(Instance, wiring.instance_id, authorize?: false) do
      {:ok, %Instance{namespace: ns} = instance} when is_binary(ns) -> {:ok, instance}
      {:ok, _undeployed} -> {:error, :not_deployed}
      {:error, _gone} -> {:error, :not_wired}
    end
  end

  defp load_pocket_id(wiring) do
    case Ash.get(Instance, wiring.pocket_id_instance_id, authorize?: false) do
      {:ok, pocket_id} -> {:ok, pocket_id}
      {:error, _gone} -> {:error, :pocket_id_gone}
    end
  end

  defp recipe(instance) do
    case Ash.load(instance, :app_version, authorize?: false) do
      {:ok, %{app_version: %{oidc_wiring: recipe}}} when not is_nil(recipe) ->
        {:ok, recipe}

      {:ok, _no_recipe} ->
        {:error, :recipe_missing}
    end
  end

  defp custody(pocket_id) do
    case PocketIdCustody.get_by_instance(pocket_id.id, authorize?: false) do
      {:ok, custody} -> {:ok, custody}
      {:error, _none} -> {:error, :no_custody}
    end
  end

  defp apply_new(instance, recipe, new_secret) do
    ApplyPocketIdEnv.apply_to_running(instance, %{recipe.client_secret_env => new_secret})
  end

  # Step 3, best-effort BY DESIGN: a refused delete leaves a harmless
  # second active secret (PocketID's admin shows it); the rotation is
  # complete and the answer stays :ok.
  defp delete_old(pocket_id, key, wiring) do
    url = base_url(pocket_id)
    client_id = wiring.pocket_id_client_id

    result =
      ApiClient.delete_secret(url, key, client_id, wiring.pocket_id_secret_id)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "PocketID old-secret delete refused after rotation (client " <>
            "#{wiring.pocket_id_client_id}): #{inspect(reason)} — the old secret stays " <>
            "active in PocketID, deletable there"
        )
    end
  end

  defp move_secret_id(wiring, new_secret_id) do
    wiring
    |> Ash.Changeset.for_update(:rotate_secret, %{pocket_id_secret_id: new_secret_id},
      authorize?: false
    )
    |> Ash.update()
  end

  defp base_url(%Instance{slug: slug}) do
    "https://#{slug}.#{Application.fetch_env!(:flux_vale, :instances_base_domain)}"
  end

  # ≥16 printable ASCII (v2.19.2's floor): 32 url-safe bytes.
  defp generated_secret do
    @secret_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
