defmodule FluxVale.Infrastructure.Operations.ConnectPocketId do
  @moduledoc """
  The pre-deploy wiring operation (#597 S4, §4.5) — the ONE seam every
  PocketID SSO wiring rides (the wizard's submit calls it directly; the
  API action dispatches here for not-yet-deployed rows and to
  `retrofit/3` for deployed ones; the wizard is sugar, not a parallel
  implementation):

  1. refuse unless the `pocketid_sso_wiring` flag is on — fail-closed
     at the seam, the §9 instant-shutdown lever for upstream API
     drift (the wizard's offer already hides under it; this is the
     server-side backstop);
  2. re-read the app instance through the authorized seam (the member
     fence) and guard its status: this PRE-DEPLOY seam lands wiring on
     NOT-YET-DEPLOYED instances only (`:pending`/`:error`/`:lost` — env
     ships on the next deploy, §4.5's sequencing). A deployed instance
     (running, stopped, sleeping, mid-deploy) carries a live env Secret
     that a row write cannot reach — that is the retrofit's lane
     (`retrofit/3`, below; the API action dispatches it), and this seam
     refuses with `{:error, :instance_running}` naming exactly that. A
     `:deleting` instance refuses as `:instance_deleting` — nothing to
     wire on the way out;
  3. read the recipe from the instance's app version (nil or `:in_app`
     refuses honestly — env injection is the v1 kind);
  4. load the chosen PocketID instance, org-fenced to the app
     instance's org (mismatch = `{:error, :forbidden}`) and public (a
     private PocketID serves no issuer, §4.1);
  5. custody for that PocketID (no row = `{:error, :no_custody}`);
  6. fetch discovery FRESH through the PocketID's public URL — the
     issuer is the document's string VERBATIM (§4.4: catches owner
     APP_URL drift; S3's wizard-lifetime probe cache answers a
     different question and is never trusted here);
  7. mint the client with the held key through `use_pocket_id_key`
     (the audited seam — the mint IS a key use, event purpose
     "client_mint", no duplicate event machinery here);
  8. in ONE transaction: force-merge the recipe's keys onto the
     instance's `env_vars` (user env untouched — a system update
     touching only the recipe's keys, so a crafted ride-along value
     under a recipe name can never win) and record the wiring row
     (replacing any prior one — one active wiring per instance).

  Failure posture is D3's spine: NOTHING here blocks a deploy. Every
  `{:error, reason}` is a visible, retryable answer — the instance
  stays exactly as it was (wiring recorded or absent, env untouched),
  and the caller offers retry-or-continue. The PocketID client mint
  precedes the transaction, so a DB failure can orphan a client in
  PocketID: harmless and visible there (named `FluxVale · …`), the D6
  posture until S5's cleanup.
  """

  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceEnvSecret
  alias FluxVale.Infrastructure.Operations.UsePocketIdKey
  alias FluxVale.Infrastructure.PocketId.ApiClient
  alias FluxVale.Infrastructure.PocketIdCustody
  alias FluxVale.Infrastructure.PocketIdWiring
  alias FluxVale.Ops.FeatureFlags
  alias FluxVale.Repo

  require Ash.Query

  # §4.5: the statuses whose next deploy (re)ships env from the row —
  # the complete set this operation may touch.
  @wireable_statuses [:pending, :error, :lost]

  # PocketID's create DTO caps the name at 50 RUNES (v2.19.2
  # `binding:"required,max=50"` — codepoints, not graphemes); the
  # prefix leaves 39 for the instance's own name. Sliced by
  # codepoints: a grapheme can span several (combining accents, emoji
  # sequences), and grapheme slicing could exceed a codepoint cap.
  @client_name_prefix "FluxVale · "
  @client_name_budget 39

  @doc """
  `{:ok, wiring}` — the recorded row (the durable record; the secret
  lives only in the instance's env_vars) — or `{:error, reason}`,
  reason one of:

  - `:flag_disabled` — the flow is off (fail-closed, unseeded in prod)
  - the authorized read's own error (non-member = Forbidden)
  - `{:instance_running, status}` — deployed; S5's rollout primitive
    is needed (the status names which posture blocked it)
  - `:instance_deleting` — the instance is on its way out; nothing
    to wire
  - `:recipe_missing` / `:recipe_not_env` / `:no_callback_path`
  - `:pocket_id_not_found` / `:forbidden` (org fence) / `:not_public`
  - `:no_custody`
  - `:unreachable` (discovery or mint transport — the wake-race,
    ADR-0036) / `:no_issuer` (answered, but no issuer published)
  - `:key_rejected` (401) / `:key_forbidden` (403) at the mint
  - `:no_created_secret` (a 2xx mint answered with no secret — the
    instance's client-secret settings)
  - `:no_api_key` / `:api_key_malformed` (custody Secret unreadable)
  - `%{status:, body:}` (a refused mint — e.g. a 400) as-is

  `opts` carry `actor:` / `authorize?:` (the caller's seam posture).
  """
  @spec call(Instance.t(), Ash.UUID.t(), keyword()) ::
          {:ok, PocketIdWiring.t()} | {:error, term()}
  def call(%Instance{id: app_instance_id}, pocket_id_instance_id, opts \\ []) do
    actor = opts[:actor]
    authorize? = Keyword.get(opts, :authorize?, true)

    with :ok <- flag_guard(),
         {:ok, app_instance} <- load_wireable(app_instance_id, actor, authorize?),
         {:ok, recipe, callback_path} <- recipe(app_instance),
         {:ok, pocket_id} <- pocket_id(pocket_id_instance_id, app_instance),
         {:ok, custody} <- custody(pocket_id),
         {:ok, issuer} <- discover(pocket_id),
         {:ok, key} <-
           UsePocketIdKey.call(custody, "client_mint", actor: actor, authorize?: authorize?),
         {:ok, client} <- mint(pocket_id, key, app_instance, callback_path, recipe) do
      record(app_instance, pocket_id, recipe, issuer, client)
    end
  end

  @doc """
  The retrofit (#597 S5, §4.6) — the SAME wiring pipeline for a
  DEPLOYED instance (app predates the PocketID): the mint and the
  atomic row+wiring write are identical to `call/3`; only the status
  guard flips to the deployed set, and after the transaction the new
  env reaches the RUNNING workload through the SSO-scoped apply
  primitive (Secret merge-upsert + rolling restart — D5's narrow
  primitive, never arbitrary env).

  The row write precedes the apply (the row is the truth; a failed
  apply leaves a recorded wiring with stale pods — visible, retryable,
  converging — never undocumented live values).
  """
  @spec retrofit(Instance.t(), Ash.UUID.t(), keyword()) ::
          {:ok, PocketIdWiring.t()} | {:error, term()}
  def retrofit(%Instance{id: app_instance_id}, pocket_id_instance_id, opts \\ []) do
    actor = opts[:actor]
    authorize? = Keyword.get(opts, :authorize?, true)

    with :ok <- flag_guard(),
         {:ok, app_instance} <- load_deployed(app_instance_id, actor, authorize?),
         {:ok, recipe, callback_path} <- recipe(app_instance),
         {:ok, pocket_id} <- pocket_id(pocket_id_instance_id, app_instance),
         {:ok, custody} <- custody(pocket_id),
         {:ok, issuer} <- discover(pocket_id),
         {:ok, key} <-
           UsePocketIdKey.call(custody, "client_mint", actor: actor, authorize?: authorize?),
         {:ok, client} <- mint(pocket_id, key, app_instance, callback_path, recipe) do
      apply_after_record(
        record(app_instance, pocket_id, recipe, issuer, client, &deployed_guard/1),
        app_instance,
        recipe,
        issuer,
        client
      )
    end
  end

  # The retrofit's tail: the row+wiring transaction committed — now
  # carry the env to the RUNNING workload. The row is truth; the pods
  # lag on failure — the card's retry converges (idempotent upsert +
  # re-roll).
  defp apply_after_record({:ok, wiring}, app_instance, recipe, issuer, client) do
    # Non-bang: the row can die between commit and here (teardown
    # serialized past the txn's lock and destroyed it) — an error
    # tuple, never a crash in the caller's LiveView.
    case Ash.reload(app_instance, authorize?: false) do
      {:ok, fresh} ->
        case InstanceEnvSecret.apply_locked(
               fresh,
               sso_env(recipe, issuer, client),
               [],
               map_size(app_instance.env_vars) > 0
             ) do
          :ok -> {:ok, wiring}
          {:error, _apply_reason} = error -> error
        end

      # coveralls-ignore-start - the teardown-race arm: the instance
      # row died between the wiring transaction's commit and this
      # read (teardown serialized past the lock and destroyed it) —
      # the window ExUnit cannot stage deterministically (#86).
      {:error, _gone} ->
        {:error, :instance_gone}

        # coveralls-ignore-stop
    end
  end

  defp apply_after_record({:error, _reason} = error, _app, _recipe, _issuer, _client),
    do: error

  # ------------------------------------------------------------------
  # Guards + reads
  # ------------------------------------------------------------------

  defp flag_guard do
    if FeatureFlags.enabled?(:pocketid_sso_wiring),
      do: :ok,
      else: {:error, :flag_disabled}
  end

  # The member fence (the authorized re-read — a non-member's struct
  # is Forbidden here whatever they hand in) plus the deploy-state
  # guard: wiring touches only instances whose NEXT deploy ships env.
  defp load_wireable(app_instance_id, actor, authorize?) do
    with {:ok, app_instance} <-
           Instance.get_by_id(app_instance_id, actor: actor, authorize?: authorize?),
         :ok <- status_guard(app_instance) do
      {:ok, app_instance}
    end
  end

  defp status_guard(%Instance{status: status}) when status in @wireable_statuses, do: :ok

  # A deleting instance is not "running" — the honest words differ
  # (nothing to wire, nothing landing with the instance page).
  defp status_guard(%Instance{status: :deleting}), do: {:error, :instance_deleting}

  defp status_guard(%Instance{status: status}), do: {:error, {:instance_running, status}}

  # The retrofit's mirror of the member fence + guard: the instance
  # must be DEPLOYED (a namespace to reach) and not on its way out.
  # The deployed set is the funnel's live-workload statuses — anything
  # else routes to the wizard path (or refuses honestly).
  @deployed_statuses [:deploying, :starting, :running, :stopped, :sleeping, :restoring]

  defp load_deployed(app_instance_id, actor, authorize?) do
    with {:ok, app_instance} <-
           Instance.get_by_id(app_instance_id, actor: actor, authorize?: authorize?),
         :ok <- deployed_guard(app_instance) do
      {:ok, app_instance}
    end
  end

  defp deployed_guard(%Instance{status: :deleting}), do: {:error, :instance_deleting}

  defp deployed_guard(%Instance{status: status}) when status in @deployed_statuses,
    do: :ok

  defp deployed_guard(%Instance{status: status}), do: {:error, {:instance_not_deployed, status}}

  # Fresh discovery through the PocketID's own public URL — never a
  # cached answer (§4.4: the wizard's probe cache answers setup
  # reachability, a different question, and could pin a stale issuer).
  # Any non-2xx folds to :unreachable at this seam: the issuer cannot
  # be derived, the dominant cause is the wake-race 503 (ADR-0036),
  # and the caller's choice (retry / continue) is the same either
  # way. :no_issuer stays distinct — the host answered, broken.
  defp discover(pocket_id) do
    url = base_url(pocket_id)
    result = ApiClient.get_discovery(url)
    discovery_result(result)
  end

  defp discovery_result({:ok, issuer}), do: {:ok, issuer}
  defp discovery_result({:error, %{status: _refused}}), do: {:error, :unreachable}
  defp discovery_result({:error, _other} = error), do: error

  # The recipe from the instance's own version (the snapshot stance —
  # the blueprint it was created from): nil = the version offers no
  # automatic wiring; `:in_app` = mint-and-show, a v2 kind this v1
  # operation honestly refuses. A recipe without a callback path
  # cannot name the client's redirect URL — `oidc_callback_path` is
  # optional catalog data (#511's stance), so the refusal is real,
  # not defensive.
  defp recipe(app_instance) do
    case Ash.load(app_instance, :app_version, authorize?: false) do
      {:ok, %{app_version: version}} ->
        wiring = version.oidc_wiring

        cond do
          is_nil(wiring) -> {:error, :recipe_missing}
          wiring.kind != :env -> {:error, :recipe_not_env}
          is_nil(version.oidc_callback_path) -> {:error, :no_callback_path}
          true -> {:ok, wiring, version.oidc_callback_path}
        end

      # coveralls-ignore-start - defensive: a DB read failure here
      # (the outage ExUnit cannot stage — DBConnection reconnects by
      # design) is an error tuple for the caller's fail-soft arm,
      # never a crash.
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  # The chosen PocketID instance, org-fenced by explicit comparison:
  # one deterministic answer shape for actor and system callers alike
  # (an authorized read would give the same verdict as a policy
  # error struct, at the cost of two shapes for the UI to render).
  defp pocket_id(pocket_id_instance_id, app_instance) do
    case Ash.get(Instance, pocket_id_instance_id, authorize?: false) do
      {:ok, %Instance{} = pocket_id} ->
        if pocket_id.organization_id == app_instance.organization_id do
          {:ok, pocket_id}
        else
          {:error, :forbidden}
        end

      {:error, _unknown} ->
        {:error, :pocket_id_not_found}
    end
  end

  # A private PocketID serves no issuer (§4.1) and its API is
  # unreachable from here — refuse before any HTTP call.
  defp custody(%Instance{id: id, exposure: :public}) do
    case PocketIdCustody.get_by_instance(id, authorize?: false) do
      # authorize?: false — the org fence already passed on the
      # instance reads above (the set_pocket_id_key stance).
      {:ok, custody} -> {:ok, custody}
      {:error, _none} -> {:error, :no_custody}
    end
  end

  defp custody(%Instance{}), do: {:error, :not_public}

  # ------------------------------------------------------------------
  # The mint
  # ------------------------------------------------------------------

  defp mint(pocket_id, key, app_instance, callback_path, recipe) do
    url = base_url(pocket_id)

    attrs = %{
      name: client_name(app_instance),
      callback_url: callback_url(app_instance, callback_path),
      pkce: recipe.pkce
    }

    # Bind then map (the credo deadlock on result-mapping helpers):
    # 401/403 fold to the wiring's honest key verdicts; every other
    # ApiClient error (transport, refused) passes through as-is.
    outcome = ApiClient.create_client(url, key, attrs)
    mint_result(outcome)
  end

  defp mint_result({:ok, client}), do: {:ok, client}
  defp mint_result({:error, :unauthorized}), do: {:error, :key_rejected}
  defp mint_result({:error, :forbidden}), do: {:error, :key_forbidden}
  defp mint_result({:error, _other} = error), do: error

  # ------------------------------------------------------------------
  # The record: env merge + wiring row, one transaction
  # ------------------------------------------------------------------

  # Atomic by design (the debit_wallet stance): a DB failure can
  # never leave a recorded wiring whose env never landed, nor merged
  # env no row describes — D3's "wiring either recorded or absent".
  # The network legs above took seconds, so the row is re-read LOCKED
  # here: a deploy that raced the window serializes behind this
  # transaction or refuses cleanly at the re-guard, and the merge
  # builds from the row's CURRENT env — a concurrent env write cannot
  # be lost to a stale snapshot (the last_owner_guard lock stance).
  # Notifications ride out of the transaction and fire after commit
  # (return_notifications?, the post_entry stance): a rollback never
  # publishes. A refusal here can orphan the minted client in
  # PocketID: harmless and visible there (D6), S5's cleanup.
  defp record(app_instance, pocket_id, recipe, issuer, client) do
    record(app_instance, pocket_id, recipe, issuer, client, &status_guard/1)
  end

  # `guard/1` is the re-read re-guard: the pre-deploy path re-checks
  # the wireable set; the retrofit re-checks the deployed set (the
  # locked row must STILL be what the caller fenced).
  defp record(app_instance, pocket_id, recipe, issuer, client, guard) do
    result =
      Repo.transaction(fn ->
        locked = lock_instance!(app_instance.id)
        merged = Map.merge(locked.env_vars, sso_env(recipe, issuer, client))

        with :ok <- guard.(locked),
             {:ok, _env, env_notifications} <- apply_env(locked, merged),
             :ok <- replace_existing_wiring(app_instance.id),
             {:ok, wiring, wiring_notifications} <-
               PocketIdWiring.record(
                 %{
                   instance_id: app_instance.id,
                   pocket_id_instance_id: pocket_id.id,
                   pocket_id_client_id: client.client_id,
                   pocket_id_secret_id: client.secret_id
                 },
                 # authorize?: false — this operation's member fence and
                 # status guards already passed (the funnel's posture).
                 authorize?: false,
                 return_notifications?: true
               ) do
          {wiring, env_notifications ++ wiring_notifications}
        else
          # coveralls-ignore-start - DB-outage class: both writes are
          # local Ash writes whose failure mode ExUnit cannot stage
          # (DBConnection reconnects by design) — the rollback keeps
          # the atomicity honest, never a half-wired state.
          {:error, reason} ->
            Repo.rollback(reason)
            # coveralls-ignore-stop
        end
      end)

    case result do
      {:ok, {wiring, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, wiring}

      # coveralls-ignore-start - the rollback's passthrough (the arm
      # above is its only producer — same unstagedable class).
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  # The write-transaction's locked re-read (last_owner_guard's lock
  # stance): FOR UPDATE inside the transaction serializes the row
  # against a racing deploy's writes.
  defp lock_instance!(instance_id) do
    Instance
    |> Ash.Query.filter(id == ^instance_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(authorize?: false)
  end

  # The system funnel on Instance: force_change the MERGED map (user
  # env preserved by the merge, recipe keys owned by the wiring) —
  # the action accepts nothing, so no caller can route arbitrary env
  # through it. return_notifications? — the caller is inside a
  # transaction and re-sends them after commit (above).
  defp apply_env(app_instance, merged) do
    changeset =
      Ash.Changeset.for_update(app_instance, :merge_system_env, %{env: merged}, authorize?: false)

    Ash.update(changeset, return_notifications?: true)
  end

  # A re-wire replaces: the identity holds one active row, and the
  # new row must land after the old one is gone (the PocketID-side
  # old-client cleanup is S5's best-effort, D6).
  defp replace_existing_wiring(app_instance_id) do
    case PocketIdWiring.get_by_instance(app_instance_id, authorize?: false) do
      {:ok, existing} -> PocketIdWiring.replace(existing, authorize?: false)
      {:error, _none} -> :ok
    end
  end

  # The recipe's keys, the wiring's values — strings end to end (the
  # k8s Secret's exact contents): the issuer VERBATIM from discovery,
  # PocketID's client id, the one-time secret, and "true" on the
  # optional toggle when the recipe names one.
  defp sso_env(recipe, issuer, client) do
    env = %{
      recipe.issuer_env => issuer,
      recipe.client_id_env => client.client_id,
      recipe.client_secret_env => client.secret
    }

    put_enabled(env, recipe.enabled_env)
  end

  defp put_enabled(env, nil), do: env
  defp put_enabled(env, enabled_env), do: Map.put(env, enabled_env, "true")

  # ------------------------------------------------------------------
  # URL + name derivations (each operation owns its own — the
  # set_pocket_id_key/deploy_instance stance for this same string)
  # ------------------------------------------------------------------

  # The instance's public URL — the same derivation the deployer seeds
  # APP_URL from and the wizard's offer copy shows. No trailing slash
  # (an API base URL).
  defp base_url(%Instance{slug: slug}) do
    "https://#{slug}.#{Application.fetch_env!(:flux_vale, :instances_base_domain)}"
  end

  # The callback the minted client registers: the app instance's
  # public URL + the version's OIDC callback path (#511's contract —
  # PocketID only redirects to listed callbacks).
  defp callback_url(%Instance{slug: slug}, callback_path) do
    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)
    "https://#{slug}.#{base_domain}#{callback_path}"
  end

  # Recognizable in the PocketID admin UI (§4.3): the platform's mark
  # plus the instance's own name, truncated to PocketID's 50-RUNE cap
  # (codepoint-sliced — see @client_name_budget).
  defp client_name(%Instance{name: name}) do
    kept =
      name
      |> String.codepoints()
      |> Enum.take(@client_name_budget)

    @client_name_prefix <> Enum.join(kept)
  end
end
