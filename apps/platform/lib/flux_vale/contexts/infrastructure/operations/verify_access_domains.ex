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

  **The arms follow the domain (ADR-0040 Am. 1 as built):** promotion
  to `:verified` mints the access arms for the domain's attached
  private instances (a fresh domain answers now, not at the next
  unrelated flip). `:failed` demotes NOTHING — a failed domain never
  routed (unverified rows are skipped at mint, and `:failed` only ever
  comes from `:pending`), so its hostnames' routes are the OTHER
  domains' routes, still standing. `:needs_attention` KEEPS serving —
  the reconcile limb is healing and the cert is still valid (the TLS
  clause routes needs_attention rows that carry a ref). The one
  honest-dark demotion is a SUSPENDED verified domain's — domain-scoped,
  via `EdgeRoutes.apply_access_none_for_domain/3` — and that is the
  limb S6's ladder calls when its writer lands. And every pass
  re-ensures the cert REPLICA of each `:verified` domain into each
  serving namespace (SSA no-op when unchanged; a renewal rotation
  converges within one cadence).

  Everything else (platform rows, `:suspended`, transient
  cluster errors) is left alone: a suspension is the billing ladder's
  (S6) authority, and a flaky read must not flap a row — the next tick
  re-decides. A transition write that re-reads a row whose state moved
  since the pass read it is skipped (a stale demotion must not
  overwrite a newer promotion).

  Runs authorize?-free by construction — the platform's read of the
  cluster, system context like every observer.
  """

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Certificate
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS

  require Ash.Query
  require Logger

  @zero_counts %{verified: 0, failed: 0, needs_attention: 0, land_errors: 0}

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
  # ladder's authority (S6) — the observer writes over neither.
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
  # concurrent promotion, an S6 suspension), skip — a stale demotion
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
    config = Application.fetch_env!(:flux_vale, :access_domains)

    case Certificate.create(
           kubeconfig,
           Keyword.fetch!(config, :certificate_namespace),
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
    config = Application.fetch_env!(:flux_vale, :access_domains)

    Certificate.get(
      kubeconfig,
      Keyword.fetch!(config, :certificate_namespace),
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

  # Public: the S6 ladder's suspension removes exactly this
  # population's routes (honest dark for the domain), and the resume
  # re-arms it — one selector, three consumers, or the notion forks.
  @doc """
  The instances that actually serve this domain through the access
  edge: the domain's hostnames' instances that are private (an
  attached public row holds no access arms — the toggle removed them)
  and attached (a pairing row — without one nothing can deliver, and
  apply_access_none's own read drives removal).
  """
  @spec serving_instances(AccessDomain.t()) :: [Instance.t()]
  def serving_instances(domain) do
    InstanceHostname
    |> Ash.Query.filter(access_domain_id == ^domain.id)
    |> Ash.read!(authorize?: false)
    |> Enum.uniq_by(& &1.instance_id)
    |> Enum.flat_map(fn hostname ->
      case Ash.get(Instance, hostname.instance_id, authorize?: false) do
        {:ok, %{exposure: :private} = instance} ->
          case AccessRoute.get_by_instance(instance.id, authorize?: false) do
            {:ok, _pairing} -> [instance]
            {:error, _unattached} -> []
          end

        _not_private_or_gone ->
          []
      end
    end)
  end

  defp mint_domain_arms(domain, kubeconfig) do
    domain
    |> serving_instances()
    |> Enum.each(&mint_instance_arms(&1, kubeconfig))

    :ok
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
end
