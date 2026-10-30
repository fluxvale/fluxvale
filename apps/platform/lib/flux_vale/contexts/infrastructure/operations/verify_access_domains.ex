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

  Everything else (platform rows, `:failed`, `:suspended`, transient
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
      counts =
        AccessDomain
        |> Ash.Query.filter(kind == :custom)
        |> Ash.read!(authorize?: false)
        |> Enum.reduce(@zero_counts, fn domain, acc ->
          tally(observe(domain, kubeconfig), acc)
        end)

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
      {:ok, body} -> decide_pending(domain, ready(body), body)
      {:error, %Error{reason: :not_found}} -> pending_certificate_missing(domain, kubeconfig)
      {:error, reason} -> log_read_failure(domain, reason)
    end
  end

  defp observe(%AccessDomain{state: :verified} = domain, kubeconfig) do
    case get_certificate(domain, kubeconfig) do
      {:ok, body} ->
        if ready(body) == "False" do
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
          promote_to_verified(domain, body)
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

  defp decide_pending(domain, "True", body), do: promote_to_verified(domain, body)

  defp decide_pending(domain, _not_ready_yet, _body) do
    if deadline_lapsed?(domain) do
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
      land(domain, :mark_failed)
    else
      reapply_certificate(domain, kubeconfig)
      :unchanged
    end
  end

  # ------------------------------------------------------------------
  # Writes — system funnels, authorize?: false (the ops seam)
  # ------------------------------------------------------------------

  defp promote_to_verified(domain, body) do
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
          {:ok, _updated} ->
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
end
