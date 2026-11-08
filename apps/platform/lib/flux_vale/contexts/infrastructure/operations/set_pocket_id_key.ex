defmodule FluxVale.Infrastructure.Operations.SetPocketIdKey do
  @moduledoc """
  Stores the org's PocketID admin API key (#597 §4.3) — the
  SetAccessApiToken discipline to the letter:

  - **owner-only** (ActorIsOrganizationOwner — this key is full admin
    over the org's identity provider, the crown-jewel stance);
  - **verified live first**: `GET /api/oidc/clients` with the key must
    answer 2xx before anything is stored; a rejected or unreachable
    PocketID stores nothing;
  - **Secret first, row second** (the recovery property): the key
    lands in a K8s Secret in the access namespace — SSA upsert, so a
    re-paste replaces — and only then does the custody row record the
    Secret's NAME. The key never reaches Postgres, never logs, and no
    user surface reads it back (`use_pocket_id_key` is the only read
    seam, internal-only);
  - **audited** (the D1 amendment): the paste-time verification is a
    key USE, and the store/replace is a custody operation — both land
    custody events.

  The expiry shown on the card is a best-effort nicety: after a
  successful verification, the key's own family is listed and the
  just-used key (lastUsedAt ≈ now) correlated; ambiguous or failed →
  nil ("managed in Pocket ID"). Never a gate.

  Which instances: the PocketID instance page's card is the caller —
  this op does not re-derive the app slug (detection is #597 S3's
  read), but it DOES refuse a private instance: a private PocketID
  serves no issuer (§4.1) and its API is unreachable from here, so
  custody over it would be dead weight from birth.
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.RecordCustodyEvent
  alias FluxVale.Infrastructure.PocketId.ApiClient
  alias FluxVale.Infrastructure.PocketIdCustody

  @secret_prefix "fluxvale-pocketid-custody"
  @api_key_data_key "POCKETID_API_KEY"

  # The correlation window: the verification call stamps the used
  # key's lastUsedAt at "now"; a listing key whose lastUsedAt falls
  # outside this window around the call is a different, idle key.
  # Exactly one in-window key = unambiguous.
  @correlation_window_seconds 300

  @doc """
  `{:ok, custody}` or `{:error, reason}` — reason being Forbidden,
  `:not_org_owner`, `:not_public`, `:unauthorized`, `:forbidden`,
  `:unreachable`, or the Secret/row write failure. The return never
  carries the key; `opts` carry `actor:` / `authorize?:`.
  """
  @spec call(Instance.t(), String.t(), keyword()) ::
          {:ok, PocketIdCustody.t()} | {:error, term()}
  def call(%Instance{} = instance, api_key, opts \\ [])
      when is_binary(api_key) do
    actor = opts[:actor]
    authorize? = Keyword.get(opts, :authorize?, true)

    with {:ok, instance} <- Instance.get_by_id(instance.id, actor: actor, authorize?: authorize?),
         :ok <- ensure_org_owner(instance, actor),
         :ok <- ensure_public(instance),
         :ok <- verify(instance, api_key) do
      # The paste-time verification IS a key use (D1): audited before
      # anything is stored, attributed to the acting owner.
      record_event(instance, :used, "verification", actor)

      store(instance, api_key, actor)
    end
  end

  # The probe against the RE-READ instance's URL (the caller's struct
  # may be stale), 2xx = a working admin key.
  defp verify(instance, api_key) do
    url = base_url(instance)
    ApiClient.verify_admin_key(url, api_key)
  end

  defp store(instance, api_key, actor) do
    verified_at = DateTime.utc_now()

    with {:ok, ref} <- write_secret(instance, api_key),
         {:ok, custody, kind} <- upsert_row(instance, ref, verified_at, expiry(instance, api_key)) do
      record_event(instance, kind, nil, actor)
      {:ok, custody}
    end
  end

  # Secret first, row second — the recovery property (the moduledoc).
  # The name is per-instance, the namespace is the platform-owned
  # access namespace (the api-credential Secret's home, ADR-0040 §5).
  defp write_secret(instance, api_key) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance) do
      data = %{@api_key_data_key => api_key}

      case Secret.create(
             kubeconfig,
             InstanceK8s.gateway_access_namespace(),
             secret_name(instance),
             data
           ) do
        {:ok, _secret} -> {:ok, secret_name(instance)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp secret_name(%Instance{id: id}), do: "#{@secret_prefix}-#{id}"

  # Upsert by identity: a re-paste updates the existing row in place
  # (one custody per instance, the identity's guarantee). Returns the
  # landed row plus the audit kind — :stored for a first paste,
  # :replaced when a row was already there.
  defp upsert_row(instance, ref, verified_at, expires_at) do
    attrs = %{api_key_secret_ref: ref, verified_at: verified_at, expires_at: expires_at}

    case PocketIdCustody.get_by_instance(instance.id, authorize?: false) do
      {:ok, %PocketIdCustody{} = existing} ->
        # authorize?: false — this operation's authorization already
        # happened on the read above (the set_api_token_ref stance).
        with {:ok, row} <- PocketIdCustody.record_replacement(existing, attrs, authorize?: false) do
          {:ok, row, :replaced}
        end

      _no_row_yet ->
        # authorize?: false, same stance: the op's owner gate passed;
        # the create funnel exists for this call alone.
        create_attrs =
          Map.merge(attrs, %{organization_id: instance.organization_id, instance_id: instance.id})

        with {:ok, row} <- PocketIdCustody.record(create_attrs, authorize?: false) do
          {:ok, row, :stored}
        end
    end
  end

  # ------------------------------------------------------------------
  # The expiry nicety
  # ------------------------------------------------------------------

  # Best-effort, never a gate: list the key's family, find the one
  # key used just now (lastUsedAt within the window), read its
  # expiresAt. Zero or several in-window keys, any API failure, an
  # unparseable timestamp — all degrade to nil ("managed in Pocket
  # ID" on the card).
  defp expiry(instance, api_key) do
    now = DateTime.utc_now()
    url = base_url(instance)

    case ApiClient.list_api_keys(url, api_key) do
      {:ok, keys} -> correlate_expiry(keys, now)
      _nicety_failure -> nil
    end
  end

  defp correlate_expiry(keys, now) do
    in_window = Enum.filter(keys, &used_recently?(&1, now))

    case in_window do
      [only] -> parse_expiry(only["expiresAt"])
      _ambiguous_or_none -> nil
    end
  end

  defp used_recently?(key, now) do
    case parse_dt(key["lastUsedAt"]) do
      %DateTime{} = last_used ->
        diff = abs(DateTime.diff(last_used, now, :second))
        diff <= @correlation_window_seconds

      _never_used_or_unparseable ->
        false
    end
  end

  defp parse_expiry(nil), do: nil

  defp parse_expiry(raw) do
    case parse_dt(raw) do
      %DateTime{} = dt -> dt
      _unparseable -> nil
    end
  end

  defp parse_dt(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _unparseable -> nil
    end
  end

  defp parse_dt(_missing), do: nil

  # ------------------------------------------------------------------
  # Guards
  # ------------------------------------------------------------------

  # The crown is the owner's to paste (SetAccessApiToken's §12
  # stance, one context over): a :member can read the card, but the
  # key they would paste is full admin over the org's identity.
  defp ensure_org_owner(_instance, nil), do: {:error, :not_org_owner}

  defp ensure_org_owner(instance, actor) do
    if ActorIsOrganizationOwner.owner?(actor, %Organization{id: instance.organization_id}) do
      :ok
    else
      {:error, :not_org_owner}
    end
  end

  # A private PocketID serves no issuer (§4.1) and its API is not
  # reachable from the platform — refuse before any HTTP call.
  defp ensure_public(%Instance{exposure: :public}), do: :ok
  defp ensure_public(%Instance{}), do: {:error, :not_public}

  # The instance's public URL — the same value the deployer seeds
  # into APP_URL (deploy_instance.ex's derivation, duplicated
  # minimally per the operations-own-their-helpers rule). No trailing
  # slash: this is an API base URL.
  defp base_url(%Instance{slug: slug}) do
    "https://#{slug}.#{Application.fetch_env!(:flux_vale, :instances_base_domain)}"
  end

  defp record_event(instance, kind, purpose, actor) do
    RecordCustodyEvent.call(%{
      organization_id: instance.organization_id,
      instance_id: instance.id,
      kind: kind,
      purpose: purpose,
      actor_id: actor && actor.id
    })
  end
end
