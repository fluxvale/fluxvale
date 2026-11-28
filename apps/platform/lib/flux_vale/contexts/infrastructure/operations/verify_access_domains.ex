defmodule FluxVale.Infrastructure.Operations.VerifyAccessDomains do
  @moduledoc """
  The observation pass for access domains (ADR-0040 S1): read every
  Certificate, land what was observed. The ONLY promoter to `:verified`
  — issuance success IS the verification, and the row may never claim a
  posture the cluster has not reported (the gateway-observer stance).

  Transitions, all idempotent and one funnel per transition:

  - `:pending` + Ready=True (with a Secret ref) → `:verified`;
    Ready=True without a ref is treated as not-ready — the row would
    claim verified with nowhere to point TLS;
  - `:pending` past `issuance_deadline_hours` without Ready=True
    (or with no Certificate object at all) → `:failed` — the owner
    removes the row, then re-registers;
  - `:verified` + Ready=False → `:needs_attention`; the object gone →
    re-applied AND `:needs_attention` (it claimed verified on a cert
    that no longer exists);
  - `:needs_attention` + Ready=True → `:verified` again — observed
    states self-heal;
  - **Reconcile limb:** a missing Certificate on a `:pending` (inside
    the window) or `:needs_attention` row is RE-APPLIED — same name,
    same Secret, same issuer (`AccessDomain.certificate_spec/1`, the
    one owner register and reconcile share) — and the row is left
    un-flapped until Ready returns. Cert loss self-heals instead of
    sticking forever.

  **Promotion is also the claim event (#756):** the domain it just
  promoted is claimed on the org's gateway when one exists, so a domain
  that verifies after the token was stored does not wait for an
  unrelated trigger.

  **The arms follow the domain (ADR-0040 Am. 1 as built):** promotion
  to `:verified` mints the arms for the domain's serving instances —
  attached private instances on the access edge, public instances on
  the public custom plane (a fresh domain answers now, not at the next
  unrelated flip), and the same enumeration re-tells each serving
  instance's running app its URL env (best-effort, warn-only).
  `:failed` demotes NOTHING — a failed domain never
  routed (unverified rows are skipped at mint, and `:failed` only ever
  comes from `:pending`), so its hostnames' routes are the OTHER
  domains' routes, still standing. `:needs_attention` KEEPS serving —
  the reconcile limb is healing and the cert is still valid (the TLS
  clause routes needs_attention rows that carry a ref). The one
  honest-dark demotion is a SUSPENDED verified domain's — domain-scoped,
  via `EdgeRoutes.apply_access_none_for_domain/3` and
  `apply_public_none_for_domain/3` — and that is the limb the
  suspension funnel calls. And every pass
  re-ensures the cert REPLICA of each `:verified` domain into each
  serving namespace (SSA no-op when unchanged; a renewal rotation
  converges within one cadence).

  **The public drift limb** is the belt the event writers cannot
  replace: every pass walks the ACTUAL `custom-*` routes in the
  verified/needs_attention domains' instance namespaces and removes any
  route with no live justification (a row-less orphan, an instance gone
  private, a domain no longer serving), re-applying the arms for the
  justified public ones — the Am. 6 drift-discipline analogue for the
  public plane, bounded by this cadence.

  Everything else (platform rows, `:suspended`, transient
  cluster errors) is left alone: a suspension is the billing ladder's
  authority, and a flaky read must not flap a row — the next tick
  re-decides. A transition write that re-reads a row whose state moved
  since the pass read it is skipped (a stale demotion must not
  overwrite a newer promotion).

  Runs authorize?-free by construction — the platform's read of the
  cluster, system context like every observer.
  """

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Certificate
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.Infrastructure.Operations.ClaimUnclaimedDomains
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.Infrastructure.Operations.SyncInstanceUrlEnv

  require Ash.Query
  require Logger

  @zero_counts %{verified: 0, failed: 0, needs_attention: 0, land_errors: 0}

  # The ownership label the public custom routes carry (stamped by the
  # mint, EdgeRoutes) — the sweep resolves a found route's domain by it.
  @access_domain_label "fluxvale.io/access-domain"

  @doc """
  `{:ok, counts}` — how many rows landed in each non-idle transition —
  or `{:error, term()}`: the platform cluster unreachable, or
  `{:land_failed, count}` when transition writes failed (the janitor
  job fails and Oban retries, instead of reporting idle success).
  """
  @spec call(keyword()) ::
          {:ok,
           %{
             verified: non_neg_integer(),
             failed: non_neg_integer(),
             needs_attention: non_neg_integer()
           }}
          | {:error, term()}
  def call(_opts \\ []) do
    with {:ok, kubeconfig} <- K8s.kubeconfig() do
      domains =
        AccessDomain
        |> Ash.Query.filter(kind == :custom)
        |> Ash.read!(authorize?: false)

      counts =
        Enum.reduce(domains, @zero_counts, fn domain, acc ->
          tally(observe(domain, kubeconfig), acc)
        end)

      # The cert-replica sync limb: every :verified domain's replica is
      # re-ensured into each serving namespace — SSA no-ops when
      # unchanged, so renewal rotations converge within one cadence.
      sync_replicas(domains, kubeconfig)

      # The public drift limb: the ROUTE-keyed belt for the public
      # custom plane (the Am. 6 analogue) — orphans included.
      sweep_public_drift(domains, kubeconfig)

      # The resolution plane's refresh (ADR-0040 §4), same cadence: the
      # Corefile re-renders from the current claims + pod IPs — the
      # pod-move refresher and the drift healer. Best-effort like every
      # render call: a failure leaves the previous view standing until
      # the next tick, never fails the pass.
      RenderAccessDNS.call()

      if counts.land_errors > 0 do
        {:error, {:land_failed, counts.land_errors}}
      else
        {:ok, Map.delete(counts, :land_errors)}
      end
    end
  end

  defp tally(:unchanged, acc), do: acc

  defp tally(transition, acc) when transition in [:verified, :failed, :needs_attention] do
    Map.update!(acc, transition, &(&1 + 1))
  end

  defp tally({:land_error, _funnel}, acc), do: Map.update!(acc, :land_errors, &(&1 + 1))

  # ------------------------------------------------------------------
  # Per-state observation
  # ------------------------------------------------------------------

  defp observe(%AccessDomain{state: :pending} = domain, kubeconfig) do
    case get_certificate(domain, kubeconfig) do
      {:ok, body} -> decide_pending(domain, kubeconfig, ready(body), body)
      {:error, %Error{reason: :not_found}} -> pending_certificate_missing(domain, kubeconfig)
      {:error, reason} -> log_read_failure(domain, reason)
    end
  end

  defp observe(%AccessDomain{state: :verified} = domain, kubeconfig) do
    case get_certificate(domain, kubeconfig) do
      {:ok, body} ->
        if ready(body) == "False" do
          # The arms KEEP SERVING here: needs_attention is the healing
          # state (the reconcile limb re-applies underneath) and the
          # issued cert is still valid — demoting now would take honest
          # hostnames dark for a row that is about to recover.
          land(domain, :mark_needs_attention)
        else
          # True (healthy) or nil (reconciling): no flap.
          :unchanged
        end

      # The object is gone: re-apply AND demote — the row claimed
      # verified on a cert that no longer exists; until Ready returns,
      # needs_attention is the honest state (the reconcile limb
      # re-applies underneath).
      {:error, %Error{reason: :not_found}} ->
        reapply_certificate(domain, kubeconfig)
        land(domain, :mark_needs_attention)

      {:error, reason} ->
        log_read_failure(domain, reason)
    end
  end

  defp observe(%AccessDomain{state: :needs_attention} = domain, kubeconfig) do
    case get_certificate(domain, kubeconfig) do
      {:ok, body} ->
        if ready(body) == "True" do
          promote_to_verified(domain, kubeconfig, body)
        else
          :unchanged
        end

      # Missing while attention already stands: re-apply, attention
      # stays until Ready returns.
      {:error, %Error{reason: :not_found}} ->
        reapply_certificate(domain, kubeconfig)
        :unchanged

      {:error, reason} ->
        log_read_failure(domain, reason)
    end
  end

  # :failed is terminal for a registration and :suspended is the billing
  # ladder's authority — the observer writes over neither.
  defp observe(%AccessDomain{}, _kubeconfig), do: :unchanged

  defp decide_pending(domain, kubeconfig, "True", body),
    do: promote_to_verified(domain, kubeconfig, body)

  defp decide_pending(domain, _kubeconfig, _not_ready_yet, _body) do
    if deadline_lapsed?(domain) do
      # No demotion on :failed: a failed domain never routed (unverified
      # rows are skipped at mint, and :failed only ever comes from
      # :pending), so its hostnames' routes are the OTHER domains'
      # routes — removing them would take honest hostnames dark for a
      # domain that never had any.
      land(domain, :mark_failed)
    else
      :unchanged
    end
  end

  # The Certificate object is missing: inside the window it is
  # re-applied (the reconcile limb) and the row waits; past the
  # deadline the window is closed — no churn for a row about to fail.
  defp pending_certificate_missing(domain, kubeconfig) do
    if deadline_lapsed?(domain) do
      # Same no-demotion stance as decide_pending.
      land(domain, :mark_failed)
    else
      reapply_certificate(domain, kubeconfig)
      :unchanged
    end
  end

  # ------------------------------------------------------------------
  # Writes — system funnels, authorize?: false (the ops seam)
  # ------------------------------------------------------------------

  defp promote_to_verified(domain, kubeconfig, body) do
    case secret_ref(body) do
      nil ->
        # Ready=True with no Secret ref is not a promotion — treat as
        # not-ready; the next tick re-decides.
        Logger.warning(
          "Access domain #{domain.domain}: Ready=True but no secretName — not promoting"
        )

        :unchanged

      secret_name ->
        case AccessDomain.mark_verified(
               domain,
               %{cert_secret_ref: secret_name},
               authorize?: false
             ) do
          {:ok, updated} ->
            # Promotion drives the arms (Am. 1 as built): the domain's
            # attached private instances' hostnames must start
            # ANSWERING now, not at the next unrelated flip.
            mint_domain_arms(updated, kubeconfig)
            claim_promoted(updated)
            :verified

          # coveralls-ignore-start - defensive: a lost write race or DB
          # failure lands here; the pass reports it so Oban retries,
          # and the sandbox cannot kill the DB
          {:error, reason} ->
            Logger.warning(
              "Access domain #{domain.domain}: verify write failed: #{inspect(reason)}"
            )

            {:land_error, :mark_verified}

            # coveralls-ignore-stop
        end
    end
  end

  # A funnel decision is only valid against the state the pass read:
  # re-read the row fresh, and if another writer moved it in between (a
  # concurrent promotion, a suspension), skip — a stale demotion
  # must not overwrite a newer write. The next tick re-decides against
  # the committed row.
  defp land(domain, funnel) do
    case AccessDomain.get_by_id(domain.id, authorize?: false) do
      {:ok, fresh} ->
        if fresh.state == expected_state(funnel) do
          write_funnel(fresh, funnel)
        else
          Logger.warning(
            "Access domain #{domain.domain}: state moved to #{fresh.state} mid-pass — " <>
              "skipping #{funnel}"
          )

          :unchanged
        end

      # The row was removed mid-pass (removal won) — nothing to write.
      {:error, _gone} ->
        Logger.warning("Access domain #{domain.domain}: removed mid-pass — skipping #{funnel}")

        :unchanged
    end
  end

  # The state each funnel's decision was made against.
  defp expected_state(:mark_failed), do: :pending
  defp expected_state(:mark_needs_attention), do: :verified

  defp write_funnel(domain, funnel) do
    case apply_funnel(domain, funnel) do
      {:ok, _updated} ->
        funnel_transition(funnel)

      # Tested at the seam (Mimic): a forced funnel error must surface
      # as {:error, {:land_failed, n}} so Oban retries.
      {:error, reason} ->
        Logger.warning(
          "Access domain #{domain.domain}: #{funnel} write failed: #{inspect(reason)}"
        )

        {:land_error, funnel}
    end
  end

  defp apply_funnel(domain, :mark_failed) do
    AccessDomain.mark_failed(domain, %{}, authorize?: false)
  end

  defp apply_funnel(domain, :mark_needs_attention) do
    AccessDomain.mark_needs_attention(domain, %{}, authorize?: false)
  end

  defp funnel_transition(:mark_failed), do: :failed
  defp funnel_transition(:mark_needs_attention), do: :needs_attention

  # ------------------------------------------------------------------
  # Cluster calls
  # ------------------------------------------------------------------

  # The reconcile limb: a missing Certificate is re-applied — same name,
  # same Secret, same issuer as registration (the shared spec owner), so
  # the SSA converges on the object registration would have made.
  # Idempotent; a failure is logged and left for the next tick (the row
  # does not flap on it).
  defp reapply_certificate(domain, kubeconfig) do
    case Certificate.create(
           kubeconfig,
           InstanceK8s.gateway_access_namespace(),
           AccessDomain.certificate_name(domain),
           AccessDomain.certificate_spec(domain)
         ) do
      {:ok, _body} ->
        Logger.warning("Access domain #{domain.domain}: Certificate missing — re-applied")

      {:error, reason} ->
        Logger.warning(
          "Access domain #{domain.domain}: Certificate re-apply failed: #{inspect(reason)}"
        )
    end
  end

  defp get_certificate(domain, kubeconfig) do
    Certificate.get(
      kubeconfig,
      InstanceK8s.gateway_access_namespace(),
      AccessDomain.certificate_name(domain)
    )
  end

  # ------------------------------------------------------------------
  # Extractions
  # ------------------------------------------------------------------

  # The Certificate's Ready condition — "True"/"False"/nil (absent or
  # malformed). Same extraction Certificate.ready_status/3 does, on a
  # body this pass already holds (one GET, not two).
  defp ready(%{"status" => %{"conditions" => conditions}}) when is_list(conditions) do
    Certificate.find_ready(conditions)
  end

  defp ready(_no_status_block), do: nil

  defp secret_ref(%{"spec" => %{"secretName" => name}}) when is_binary(name), do: name
  defp secret_ref(_body), do: nil

  defp deadline_lapsed?(domain) do
    config = Application.fetch_env!(:flux_vale, :access_domains)

    window = Keyword.fetch!(config, :issuance_deadline_hours) * 3600

    DateTime.compare(
      domain.registered_at,
      DateTime.add(DateTime.utc_now(), -window, :second)
    ) == :lt
  end

  defp log_read_failure(domain, reason) do
    Logger.warning("Access domain #{domain.domain}: Certificate read failed: #{inspect(reason)}")
    :unchanged
  end

  # ------------------------------------------------------------------
  # The domain's arms (ADR-0040 Am. 1 as built)
  # ------------------------------------------------------------------

  # Public: the suspension funnel removes exactly this population's
  # routes — BOTH planes (honest dark for the domain) — and the resume
  # re-arms them — one selector, three consumers, or the notion forks.
  @doc """
  The instances that serve this domain through EITHER plane: the
  domain's hostnames' instances that are public (the exposure IS the
  delivery path — no pairing required), or private AND attached (a
  pairing row — without one nothing can deliver, and
  apply_access_none's own read drives removal). An undeployed instance
  (no namespace) serves nothing anywhere — not a serving instance.
  """
  @spec serving_instances(AccessDomain.t()) :: [Instance.t()]
  def serving_instances(domain) do
    InstanceHostname
    |> Ash.Query.filter(access_domain_id == ^domain.id)
    |> Ash.read!(authorize?: false)
    |> Enum.uniq_by(& &1.instance_id)
    |> Enum.flat_map(fn hostname ->
      case Ash.get(Instance, hostname.instance_id, authorize?: false) do
        {:ok, %{exposure: :public, namespace: ns} = instance} when not is_nil(ns) ->
          [instance]

        {:ok, %{exposure: :private, namespace: ns} = instance} when not is_nil(ns) ->
          case AccessRoute.get_by_instance(instance.id, authorize?: false) do
            {:ok, _pairing} -> [instance]
            {:error, _unattached} -> []
          end

        # Undeployed (no namespace — a row can exist before the deploy)
        # or the row's instance gone: nothing serves.
        _not_deployed_or_gone ->
          []
      end
    end)
  end

  # Promotion is the once-per-domain claim event (#756): the token is
  # either already stored (the common order) or the domain stays
  # unclaimed until the owner pastes one — the sweep is event-driven,
  # never a tick loop. The pass renders once at the end, so the sweep
  # does not.
  defp claim_promoted(domain) do
    case AccessGateway.get_for_organization(domain.organization_id, authorize?: false) do
      {:ok, gateway} ->
        _summary = ClaimUnclaimedDomains.call(gateway, domains: [domain], render?: false)
        :ok

      {:error, _no_gateway} ->
        Logger.info("Access domain #{domain.domain}: verified without a gateway — unclaimed")
        :ok
    end
  end

  # Promotion drives the arms (Am. 1 as built): the domain's serving
  # instances' hostnames must start ANSWERING now, not at the next
  # unrelated flip — attached private instances on the access edge,
  # public instances on the public custom plane. The SAME enumeration
  # re-tells each serving instance's running app its URL env — one
  # pass feeds both (the mark_verified write above is the primary
  # artifact the sync rides).
  defp mint_domain_arms(domain, kubeconfig) do
    domain
    |> serving_instances()
    |> Enum.each(fn instance ->
      mint_instance_arms(instance, kubeconfig)
      retell_url_env(instance)
    end)

    :ok
  end

  # Best-effort, post-commit, warn-only: a sync failure is logged and
  # never fails the promotion — the next event or a redeploy converges.
  defp retell_url_env(instance) do
    case SyncInstanceUrlEnv.call(instance) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Access domain arms: the URL-env sync failed for instance #{instance.id}: " <>
            inspect(reason)
        )

        :ok
    end
  end

  # The exposure dispatch (the one-owner rule lives in EdgeRoutes —
  # apply_public_for_status/apply_access_for_status): a public instance
  # has no pairing row to read, the private path is exactly as it was.
  defp mint_instance_arms(%{exposure: :public} = instance, kubeconfig) do
    case EdgeRoutes.apply_public_for_status(kubeconfig, instance) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Access domain arms: mint failed for instance #{instance.id}: #{inspect(reason)}"
        )
    end
  end

  defp mint_instance_arms(instance, kubeconfig) do
    with {:ok, route} <- AccessRoute.get_by_instance(instance.id, authorize?: false),
         {:ok, route} <- Ash.load(route, :gateway, authorize?: false) do
      case EdgeRoutes.apply_access_for_status(kubeconfig, route.gateway, instance) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Access domain arms: mint failed for instance #{instance.id}: #{inspect(reason)}"
          )
      end
    end
  end

  defp sync_replicas(domains, kubeconfig) do
    domains
    |> Enum.filter(&(&1.state == :verified))
    |> Enum.each(&sync_domain_replicas(&1, kubeconfig))

    :ok
  end

  defp sync_domain_replicas(domain, kubeconfig) do
    domain
    |> serving_instances()
    |> Enum.each(&ensure_replica(&1, domain, kubeconfig))
  end

  defp ensure_replica(instance, domain, kubeconfig) do
    case EdgeRoutes.ensure_access_cert_secret(kubeconfig, domain, instance.namespace) do
      {:ok, _local} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Access domain #{domain.domain}: cert replica sync into #{instance.namespace} " <>
            "failed: #{inspect(reason)}"
        )
    end
  end

  # ------------------------------------------------------------------
  # The public drift limb (the Am. 6 analogue for the public custom
  # plane, ROUTE-keyed): the belt that bounds every state the event
  # writers cannot see — including ORPHANS, the row-less routes no
  # row-keyed walk can name. Best-effort like every limb here: warn,
  # never fail the pass.
  # ------------------------------------------------------------------

  # One walk per pass, TWO halves. The routes of a domain's rows can
  # only live in the domain's org's instance namespaces (the mint's org
  # belt), so the orgs of the verified/needs_attention custom domains
  # bound the listing — and listing (not the rows) is what makes
  # orphans visible.
  defp sweep_public_drift(domains, kubeconfig) do
    serving = Enum.filter(domains, &(&1.state in [:verified, :needs_attention]))

    # The ROW-keyed re-apply half: a promotion mint that failed
    # warn-only never landed a route, so the route-keyed half can never
    # see it — the rows re-arm those instances directly (idempotent
    # SSA, the promotion mint's own call).
    Enum.each(serving, &reapply_domain_public_arms(&1, kubeconfig))

    # The ROUTE-keyed deletion half: the belt for what the rows cannot
    # name (orphans, stale mode/state).
    serving
    |> Enum.map(& &1.organization_id)
    |> Enum.uniq()
    |> Enum.flat_map(&org_instances/1)
    |> Enum.each(&sweep_instance_routes(&1, kubeconfig))

    :ok
  end

  defp reapply_domain_public_arms(domain, kubeconfig) do
    domain
    |> serving_instances()
    |> Enum.filter(&(&1.exposure == :public))
    |> Enum.each(&reapply_public_arms(&1, kubeconfig))
  end

  defp org_instances(organization_id) do
    Instance
    |> Ash.Query.filter(organization_id == ^organization_id and not is_nil(namespace))
    |> Ash.read!(authorize?: false)
  end

  defp sweep_instance_routes(instance, kubeconfig) do
    case Ingress.list_by_labels(kubeconfig, instance.namespace, %{}) do
      {:ok, routes} ->
        routes
        |> Enum.filter(&custom_route_body?/1)
        |> Enum.each(&sweep_route(&1, instance, kubeconfig))

      {:error, reason} ->
        Logger.warning(
          "Access domain arms: the public drift sweep could not list #{instance.namespace}: " <>
            inspect(reason)
        )
    end
  end

  # A live justification is ALL of: the route's label names a custom
  # domain in a serving state, the name tail matches a current
  # InstanceHostname row, and that row's instance is public in this
  # namespace. Anything else comes down — a row-less orphan, an
  # instance gone private, a domain no longer serving. A justified
  # route's arms are RE-APPLIED instead (idempotent SSA), so a stale
  # mode/state converges within one cadence.
  defp sweep_route(route_body, host_instance, kubeconfig) do
    namespace = host_instance.namespace

    case justified_public_instance(route_body, namespace) do
      {:ok, instance} ->
        reapply_public_arms(instance, kubeconfig)

      # Fail-safe, not fail-destructive: a FAILED observation leaves
      # the route standing (logged at the read); only an observed
      # absence justifies the delete.
      {:error, :read_failed} ->
        :ok

      {:error, _no_justification} ->
        delete_stale_route(kubeconfig, namespace, route_name(route_body))
    end
  end

  defp justified_public_instance(route_body, namespace) do
    domain = labeled_domain(route_body)

    cond do
      is_nil(domain) ->
        {:error, :domain_gone}

      domain.kind != :custom or domain.state not in [:verified, :needs_attention] ->
        {:error, :domain_not_serving}

      true ->
        row_instance(domain, route_base_name(route_body), namespace)
    end
  end

  defp row_instance(domain, base_name, namespace) do
    row =
      domain.id
      |> domain_hostname_rows()
      |> Enum.find(&(custom_route_base_name(&1.id) == base_name))

    case row do
      nil ->
        # An OBSERVED absence: no row names this route — the orphan.
        {:error, :row_gone}

      row ->
        case Instance.get_by_id(row.instance_id, authorize?: false) do
          {:ok, %{exposure: :public, namespace: ^namespace} = instance} ->
            {:ok, instance}

          {:ok, _observed_not_public_here} ->
            {:error, :instance_not_public_here}

          # A FAILED observation must not turn destructive: the route
          # stays standing, the failure logs, the next tick re-decides.
          {:error, reason} ->
            Logger.warning(
              "Access domain arms: the drift sweep could not read instance " <>
                "#{row.instance_id}: #{inspect(reason)} — leaving the route standing"
            )

            {:error, :read_failed}
        end
    end
  end

  # The re-apply: a failure is logged and left for the next tick — the
  # sweep never fails the pass over its own heals.
  defp reapply_public_arms(instance, kubeconfig) do
    case EdgeRoutes.apply_public_for_status(kubeconfig, instance) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Access domain arms: the drift sweep's re-apply failed for instance " <>
            "#{instance.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp delete_stale_route(kubeconfig, namespace, name) do
    Logger.warning(
      "Access domain arms: public drift sweep removing #{namespace}/#{name} — no live justification"
    )

    case Ingress.delete(kubeconfig, namespace, name) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Access domain arms: the drift sweep could not remove #{namespace}/#{name}: " <>
            inspect(reason)
        )

        :ok
    end
  end

  defp custom_route_body?(%{"metadata" => %{"name" => "custom-" <> _tail}}), do: true
  defp custom_route_body?(_other), do: false

  defp route_name(route_body), do: get_in(route_body, ["metadata", "name"])

  defp route_base_name(route_body) do
    route_body
    |> route_name()
    |> String.replace_suffix("-dav", "")
  end

  defp labeled_domain(route_body) do
    case get_in(route_body, ["metadata", "labels", @access_domain_label]) do
      nil ->
        nil

      id ->
        case Ash.get(AccessDomain, id, authorize?: false) do
          {:ok, domain} -> domain
          {:error, _gone} -> nil
        end
    end
  end

  defp domain_hostname_rows(domain_id) do
    InstanceHostname
    |> Ash.Query.filter(access_domain_id == ^domain_id)
    |> Ash.read!(authorize?: false)
  end

  # The public family's route-name derivation, mirrored from
  # EdgeRoutes.custom_route_name (P1 owns the mint; the sweep must
  # recognize the same names — any change there moves this mirror).
  defp custom_route_base_name(hostname_id) do
    short_id =
      hostname_id
      |> to_string()
      |> String.replace("-", "")
      |> String.slice(-10, 10)

    "custom-#{short_id}"
  end
end
