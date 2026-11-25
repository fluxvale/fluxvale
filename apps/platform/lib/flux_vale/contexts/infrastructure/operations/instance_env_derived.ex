defmodule FluxVale.Infrastructure.Operations.InstanceEnvDerived do
  @moduledoc """
  The deploy-time env derivations shared by the deploy op, the in-place
  env patch (#731 T1, ADR-0052 decision 4), and the address-event sync;
  the sign-on callback joins with a later slice. One snapshot of the
  instance's live addressing (`derive/1` — the URL and the hostname set
  from the same reads), the platform append to the catalog's
  `host_allowlist_env`, and the claimed-default-hostname predicate the
  append rides.

  One owner is the whole point: the deploy and the sync compute ONE
  snapshot and feed both env keys from it — a Secret's URL and its
  allowlist can never come from two different reads — and a patch, the
  sync, and (later) the sign-on callback all read the same answer.
  `host_allowlist_env` stays user-writable; the platform's entries ride
  on top.
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
  deploy op answers from (the sign-on callback's lib consumer lands
  with that later slice, ADR-0052). Public rows always answer on
  the default hostname. Private rows: the OLDEST live custom address
  (created_at, then id — A1's stability ruling), else the default when
  `default_hostname_live?/1`, else nil (ADR-0038 §4's omission).
  Trailing slash, mirroring the deploy seed's shape.
  """
  @spec instance_url(Instance.t()) :: String.t() | nil
  def instance_url(instance), do: derive(instance).url

  @doc """
  Every hostname the instance answers on: the default hostname when
  public or default-live, plus every live custom hostname (created_at,
  id order). The allowlist append consumes this set.
  """
  @spec serving_hostnames(Instance.t()) :: [String.t()]
  def serving_hostnames(instance), do: derive(instance).hostnames

  @doc """
  One snapshot of the instance's live addressing: the URL and the
  hostname set, from the same reads at the same instant. The deploy and
  the sync feed both env keys from it, so the Secret's URL and its
  allowlist can never come from two different states; the
  one-shot wrappers (`instance_url/1`, `serving_hostnames/1`) are for
  single-answer callers.
  """
  @spec derive(Instance.t()) :: %{url: String.t() | nil, hostnames: [String.t()]}
  def derive(instance) do
    customs = live_custom_hostnames(instance)

    default_live? = instance.exposure == :public or default_hostname_live?(instance)

    url =
      cond do
        instance.exposure == :public ->
          default_url(instance)

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
  @doc """
  Is the instance's default hostname live on a claimed domain? The
  deployer's URL/allowlist decision and the in-place patch's allowlist
  re-append share this predicate.
  """
  @spec default_hostname_live?(map()) :: boolean()
  def default_hostname_live?(instance) do
    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)

    case AccessRoute.get_by_instance(instance.id, authorize?: false) do
      {:ok, _live_pairing} ->
        claimed_on_gateway?(instance, base_domain)

      # Unattached: the pairing row simply isn't there.
      {:error, _no_pairing} ->
        false
    end
  end

  defp claimed_on_gateway?(instance, base_domain) do
    case AccessGateway.get_for_organization(instance.organization_id, authorize?: false) do
      {:ok, %{dns_claims: claims}} when is_map(claims) ->
        Map.has_key?(claims, base_domain) and platform_domain_live?(instance, base_domain)

      _no_gateway_or_claims ->
        false
    end
  end

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

  # The live custom hostnames — the mirror of default_hostname_live?/1's
  # stance (the system seam, `authorize?: false`), reading the same
  # gates in the same order: the instance is PRIVATE (custom addresses
  # never serve publicly) and ATTACHED (the same `AccessRoute` pairing
  # read; an unattached private instance answers nowhere), then each
  # row's domain is `:custom`, in a routable state, and claimed by the
  # org's gateway. Oldest first (created_at, then id — the same order
  # `list_for_instance` sorts by).
  defp live_custom_hostnames(%{exposure: :private} = instance) do
    case AccessRoute.get_by_instance(instance.id, authorize?: false) do
      {:ok, _live_pairing} ->
        claimed_custom_hostnames(instance)

      # Unattached: the pairing row simply isn't there.
      {:error, _no_pairing} ->
        []
    end
  end

  defp live_custom_hostnames(_public_row), do: []

  defp claimed_custom_hostnames(instance) do
    case AccessGateway.get_for_organization(instance.organization_id, authorize?: false) do
      {:ok, %{dns_claims: claims}} when is_map(claims) ->
        claimed_hostname_rows(instance, claims)

      _no_gateway_or_claims ->
        []
    end
  end

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
