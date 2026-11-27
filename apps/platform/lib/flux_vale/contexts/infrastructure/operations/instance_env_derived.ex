defmodule FluxVale.Infrastructure.Operations.InstanceEnvDerived do
  @moduledoc """
  The deploy-time env derivations shared by the deploy op, the in-place
  env patch (#731 T1, ADR-0052 decision 4), the address-event sync, and
  the sign-on callback. One snapshot of the instance's live addressing
  (`derive/1` — the URL and the hostname set: a private row from ONE
  pairing read, ONE gateway-claims read, and ONE hostname-rows read; a
  public row from ONE hostname-rows read alone), the platform append
  to the catalog's `host_allowlist_env`, and the
  claimed-default-hostname predicate the append rides.

  One owner is the whole point: the deploy and the sync compute ONE
  snapshot and feed both env keys from it — a Secret's URL and its
  allowlist can never come from two different reads — and a patch, the
  sync, and the sign-on callback all read the same answer.
  `host_allowlist_env` stays user-writable; the platform's entries ride
  on top.

  The public arm's rule (owner-ruled Nov 27 2026, fluxvale/fluxvale#929;
  the ADR amendment lands with the lane's docs slice): a public row's
  URL is its oldest live custom address, else the default hostname — a
  custom address is live for a public row when its domain is `:custom`,
  owned by the instance's org, and routable
  (`:verified`/`:needs_attention`); no pairing, no gateway, no claims
  read. The private arm keeps its attached-and-claimed gate.
  """

  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname

  require Ash.Query

  @doc """
  Appends the given serving hostnames (the `derive/1` snapshot's set)
  to the app's host-allowlist env. A nil `host_allowlist_env` means the
  catalog wants none; no hostnames leave the env untouched.
  """
  @spec allowlist_entry(map(), [String.t()], map()) :: map()
  def allowlist_entry(env, hostnames, app_version) do
    env_name = app_version.host_allowlist_env

    if is_binary(env_name) do
      Enum.reduce(hostnames, env, fn host, acc ->
        Map.put(acc, env_name, append_host(Map.get(acc, env_name), host))
      end)
    else
      env
    end
  end

  @doc """
  The instance's URL from its live hostnames — the ONE derivation the
  deploy op, the sync, and the sign-on callback answer from (ADR-0052).
  Public rows: the OLDEST live custom address, else the default
  hostname — the public arm's rule. Private rows: the OLDEST live
  custom address (created_at, then id — A1's stability ruling), else
  the default when the claimed-domain predicate holds, else nil
  (ADR-0038 §4's omission). Trailing slash, mirroring the deploy
  seed's shape.
  """
  @spec instance_url(Instance.t()) :: String.t() | nil
  def instance_url(instance), do: derive(instance).url

  @doc """
  Every hostname the instance answers on: the default hostname when
  public or default-live, plus every live custom hostname (created_at,
  id order). For a public row the customs are the publicly-live ones —
  the public arm's rule. The allowlist append consumes this set.
  """
  @spec serving_hostnames(Instance.t()) :: [String.t()]
  def serving_hostnames(instance), do: derive(instance).hostnames

  @doc """
  One snapshot of the instance's live addressing: the URL and the
  hostname set. A private row answers from ONE pairing read and ONE
  gateway-claims read — a claims write landing mid-derivation can
  never tear the arms apart (a URL naming a host the same snapshot no
  longer claims). A public row reads neither source (a public custom
  address serves with no gateway at all) and answers from ONE
  hostname-rows read. The deploy and the sync feed both env keys from
  the snapshot, so the Secret's URL and its allowlist can never come
  from two different states; the one-shot wrappers (`instance_url/1`,
  `serving_hostnames/1`) are for single-answer callers.
  """
  @spec derive(Instance.t()) :: %{url: String.t() | nil, hostnames: [String.t()]}
  def derive(instance) do
    snapshot = attach_and_claims(instance)

    customs = live_custom_hostnames(snapshot, instance)

    default_live? = instance.exposure == :public or hostname_default_live?(snapshot, instance)

    # The URL: the oldest live custom address when one is live, else
    # the default, else nil. The customs differ per arm (the public
    # arm's are the publicly-live rows, the private arm's the claimed
    # ones); a public row's default is always live (`default_live?` is
    # `true` for every public row), so there is no public-only clause —
    # the public arm's rule.
    url =
      cond do
        customs != [] ->
          "https://" <> hd(customs) <> "/"

        default_live? ->
          default_url(instance)

        true ->
          nil
      end

    hostnames =
      if default_live? do
        [default_hostname(instance) | customs]
      else
        customs
      end

    %{url: url, hostnames: hostnames}
  end

  # LIVE on a claimed domain: the instance is ATTACHED (a live pairing —
  # the same record attach/detach read; an unattached private instance
  # answers nowhere, so the ADR-0038 §4 omission holds), the org's
  # gateway holds the claim for the base domain, AND the platform-domain
  # row is in a routable state (`:verified`/`:needs_attention` — the
  # same mirror the TLS clause routes). No gateway, no pairing, no
  # claim → no URL.
  #
  # ENV-SNAPSHOT STANCE: the env lands on the first deploy that finds
  # these conditions true. A later unclaim/detach does NOT rewrite a
  # running app's env Secret — the seeded URL goes stale by design
  # until the next deploy re-decides (the same stance as an exposure
  # toggle: toggling later doesn't rewrite a running app's env).
  # ONE snapshot of the addressing inputs: whether the instance is
  # attached (a live AccessRoute pairing — the same record attach/detach
  # read) and, when it is, the org gateway's claims map. Both arms of
  # `derive/1` consume this map, so each source is read exactly once
  # per derivation. Public rows read neither source: a public custom
  # address serves with no gateway at all, so their live hostnames
  # come from the public arm's own hostname-rows read
  # (`live_custom_hostnames`'s public clause — the public arm's rule).
  defp attach_and_claims(%{exposure: :private} = instance) do
    case AccessRoute.get_by_instance(instance.id, authorize?: false) do
      {:ok, _live_pairing} ->
        case AccessGateway.get_for_organization(instance.organization_id, authorize?: false) do
          {:ok, %{dns_claims: claims}} when is_map(claims) ->
            {:claims, claims}

          _no_gateway_or_claims ->
            {:claims, %{}}
        end

      # Unattached: the pairing row simply isn't there.
      {:error, _no_pairing} ->
        :unattached
    end
  end

  defp attach_and_claims(_public_row), do: :unattached

  # The live custom hostnames, from the SNAPSHOT's claims — no re-read.
  defp live_custom_hostnames({:claims, claims}, instance) do
    claimed_hostname_rows(instance, claims)
  end

  # The PUBLIC arm: a public custom address serves with no gateway at
  # all — the snapshot holds no pairing and no claims for a public row
  # — so its live hostnames come from the public arm's own read below.
  defp live_custom_hostnames(_snapshot, %{exposure: :public} = instance) do
    public_hostname_rows(instance)
  end

  defp live_custom_hostnames(:unattached, _instance), do: []

  # The claimed-default-hostname predicate, from the SNAPSHOT's claims.
  # The platform-domain row read stays its own: it gates a different
  # row (the platform domain) than the claims map.
  defp hostname_default_live?({:claims, claims}, instance) do
    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)

    Map.has_key?(claims, base_domain) and platform_domain_live?(instance, base_domain)
  end

  defp hostname_default_live?(:unattached, _instance), do: false

  defp platform_domain_live?(instance, base_domain) do
    query =
      Ash.Query.filter(
        AccessDomain,
        organization_id == ^instance.organization_id and
          kind == :platform and
          domain == ^base_domain
      )

    case Ash.read_one(query, authorize?: false) do
      {:ok, %{state: state}} ->
        state in [:verified, :needs_attention]

      # coveralls-ignore-start - defensive: the row cannot be missing
      # while this instance exists (its own default hostname FK-restricts
      # the platform row — the remove path refuses first), and a read
      # failure is the DB-outage class ExUnit cannot stage. Fail closed:
      # no URL.
      _no_row_or_read_failure ->
        false
        # coveralls-ignore-stop
    end
  end

  # The live custom hostnames — the mirror of the default-hostname
  # predicate's stance (the system seam, `authorize?: false`), gated on
  # the SNAPSHOT: the instance is PRIVATE (custom addresses never serve
  # publicly) and ATTACHED (the pairing read the snapshot already made),
  # then each row's domain is `:custom`, in a routable state, and
  # claimed by the org's gateway per the snapshot's claims map. Oldest
  # first (created_at, then id — the same order `list_for_instance`
  # sorts by).
  defp claimed_hostname_rows(instance, claims) do
    query = Ash.Query.filter(InstanceHostname, instance_id == ^instance.id)

    case Ash.read(query, authorize?: false, load: [:access_domain]) do
      {:ok, rows} ->
        live =
          rows
          |> Enum.filter(&live_custom_row?(instance, &1, claims))
          # DateTime term order is NOT chronological (day compares
          # before month) — sort by the epoch integer.
          |> Enum.sort_by(&{DateTime.to_unix(&1.created_at, :microsecond), &1.id})

        Enum.map(live, &"#{&1.label}.#{&1.access_domain.domain}")

      # coveralls-ignore-start - defensive: the DB-outage class ExUnit
      # cannot stage (DBConnection reconnects by design). Fail closed —
      # no hostnames, no URL (the module's stance).
      {:error, _read_failed} ->
        []
        # coveralls-ignore-stop
    end
  end

  # LIVE: a custom-domain row in a routable state (the resolver's
  # mirror — `:verified`, or `:needs_attention`) whose domain name the
  # org's gateway claims. A pending domain, a gone row, an unclaimed
  # name — none of them answer.
  #
  # Deliberate: the derivation mirrors the RESOLVER's liveness (row
  # state + gateway claim) — the EDGE additionally gates custom TLS on
  # a recorded cert ref and a live pod. A transient edge/cert-
  # replication failure, or a suspended gateway, does NOT change the
  # instance's canonical address — the same stance the default-hostname
  # predicate has always taken. The URL names the address, not the
  # minute's reachability.
  #
  # The row's domain must also belong to the INSTANCE's org — a belt
  # matching the platform arm's local fence; the mint guard is the
  # inherited primary.
  defp live_custom_row?(instance, row, claims) do
    domain = row.access_domain

    domain.kind == :custom and
      domain.organization_id == instance.organization_id and
      domain.state in [:verified, :needs_attention] and
      Map.has_key?(claims, domain.domain)
  end

  # The PUBLIC arm's live custom hostnames: ONE hostname-rows read, no
  # re-read (the module's single-snapshot discipline), filtered by the
  # public liveness, oldest first — the same sort
  # `claimed_hostname_rows` applies (created_at, then id).
  defp public_hostname_rows(instance) do
    query = Ash.Query.filter(InstanceHostname, instance_id == ^instance.id)

    case Ash.read(query, authorize?: false, load: [:access_domain]) do
      {:ok, rows} ->
        live =
          rows
          |> Enum.filter(&public_live_row?(instance, &1))
          # DateTime term order is NOT chronological (day compares
          # before month) — sort by the epoch integer.
          |> Enum.sort_by(&{DateTime.to_unix(&1.created_at, :microsecond), &1.id})

        Enum.map(live, &"#{&1.label}.#{&1.access_domain.domain}")

      # coveralls-ignore-start - defensive: the DB-outage class ExUnit
      # cannot stage (DBConnection reconnects by design). The public
      # arm's customs are lost on the failed read; the default hostname
      # is still told, converging on the next address event.
      {:error, _read_failed} ->
        []
        # coveralls-ignore-stop
    end
  end

  # The PUBLIC arm's liveness (the public arm's rule): the row's
  # domain is `:custom`, owned by the INSTANCE's org, and in a
  # routable state (`:verified`/`:needs_attention` — the same state
  # mirror the TLS clause routes). NO pairing row, NO gateway, NO
  # `dns_claims` read: a public custom address serves with no gateway
  # at all. The private arm's predicate (`live_custom_row?/3` —
  # attached and claimed) is unchanged.
  defp public_live_row?(instance, row) do
    domain = row.access_domain

    domain.kind == :custom and
      domain.organization_id == instance.organization_id and
      domain.state in [:verified, :needs_attention]
  end

  defp default_hostname(instance) do
    "#{instance.slug}.#{Application.fetch_env!(:flux_vale, :instances_base_domain)}"
  end

  defp default_url(instance) do
    "https://" <> default_hostname(instance) <> "/"
  end

  defp append_host(nil, host), do: host

  defp append_host("", host), do: host

  defp append_host(existing, host) when is_binary(existing) do
    present? =
      existing
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.member?(host)

    if present?, do: existing, else: existing <> "," <> host
  end
end
