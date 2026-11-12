defmodule FluxVale.Infrastructure.Operations.InstanceEnvDerived do
  @moduledoc """
  The deploy-time env derivations shared by the full deploy and the
  in-place env patch (#731 T1, ADR-0052 decision 4): the platform
  hostname append to the catalog's `host_allowlist_env`, and the
  claimed-default-hostname predicate the append rides.

  One owner is the whole point: a patch and a deploy must compose the
  same allowlist value, or a running app's host-header set can drop the
  platform entry the deployer added. `host_allowlist_env` stays
  user-writable; the platform's entry rides on top.
  """

  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessRoute

  require Ash.Query

  @doc """
  Appends the platform hostname to the app's host-allowlist env when
  the instance serves it: public rows always, private rows only on a
  claimed, live default hostname. A nil `host_allowlist_env` means the
  catalog wants none.
  """
  @spec allowlist_entry(map(), map(), map()) :: map()
  def allowlist_entry(env, instance, app_version) do
    env_name = app_version.host_allowlist_env

    if is_binary(env_name) and (instance.exposure == :public or default_hostname_live?(instance)) do
      hostname = "#{instance.slug}.#{Application.fetch_env!(:flux_vale, :instances_base_domain)}"
      Map.put(env, env_name, append_host(Map.get(env, env_name), hostname))
    else
      env
    end
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

  defp append_host(nil, host), do: host
  defp append_host(existing, host) when is_binary(existing), do: "#{existing},#{host}"
end
