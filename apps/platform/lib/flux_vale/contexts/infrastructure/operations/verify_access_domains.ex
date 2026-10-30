defmodule FluxVale.Infrastructure.Operations.VerifyAccessDomains do
  @moduledoc """
  The observation pass for access domains (ADR-0040 S1): read every
  Certificate, land what was observed. The ONLY promoter to `:verified`
  — issuance success IS the verification, and the row may never claim a
  posture the cluster has not reported (the gateway-observer stance).

  Transitions, all idempotent and one funnel per transition:

  - `:pending` + Ready=True → `:verified`, `cert_secret_ref` from the
    observed Certificate's `spec.secretName` (never guessed);
  - `:pending` past `issuance_deadline_hours` without Ready=True
    (or with no Certificate object at all) → `:failed` — the owner
    re-registers;
  - `:pending`, still inside the window, Certificate missing → left
    `:pending` (cert-manager creates the object on its own clock; the
    drift is a retry's), logged;
  - `:verified` + Ready=False (or the object gone) →
    `:needs_attention`;
  - `:needs_attention` + Ready=True → `:verified` again — observed
    states self-heal.

  Everything else (platform rows, `:failed`, `:suspended`, transient
  cluster errors) is left alone: a suspension is the billing ladder's
  (S6) authority, and a flaky read must not flap a row — the next tick
  re-decides.

  Runs authorize?-free by construction — the platform's read of the
  cluster, system context like every observer.
  """

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Certificate
  alias FluxVale.Infrastructure.AccessDomain

  require Ash.Query
  require Logger

  @zero_counts %{verified: 0, failed: 0, needs_attention: 0}

  @doc """
  `{:ok, counts}` — how many rows landed in each non-idle transition —
  or `{:error, reason}` when the platform cluster itself is unreachable
  (the janitor job fails and Oban retries).
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

      {:ok, counts}
    end
  end

  defp tally(:unchanged, acc), do: acc
  defp tally(transition, acc), do: Map.update!(acc, transition, &(&1 + 1))

  # ------------------------------------------------------------------
  # Per-state observation
  # ------------------------------------------------------------------

  defp observe(%AccessDomain{state: :pending} = domain, kubeconfig) do
    case get_certificate(domain, kubeconfig) do
      {:ok, body} -> decide_pending(domain, ready(body), body)
      # cert-manager has not landed the object yet — drift a retry
      # covers, unless the wait is over.
      {:error, %Error{reason: :not_found}} -> pending_certificate_missing(domain)
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

      # The object is gone — an observed fact, not a transient read.
      {:error, %Error{reason: :not_found}} ->
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

      # Missing or unreadable while attention already stands: attention
      # is still the honest state.
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

  defp pending_certificate_missing(domain) do
    if deadline_lapsed?(domain) do
      land(domain, :mark_failed)
    else
      Logger.warning(
        "Access domain #{domain.domain}: Certificate not found yet — leaving :pending"
      )

      :unchanged
    end
  end

  # ------------------------------------------------------------------
  # Writes — system funnels, authorize?: false (the ops seam)
  # ------------------------------------------------------------------

  defp promote_to_verified(domain, body) do
    case AccessDomain.mark_verified(
           domain,
           %{cert_secret_ref: secret_ref(body)},
           authorize?: false
         ) do
      {:ok, _updated} ->
        :verified

      # coveralls-ignore-start - defensive: a lost write race or DB
      # failure lands here; the next tick re-reads and re-decides, and
      # the sandbox cannot kill the DB
      {:error, reason} ->
        Logger.warning("Access domain #{domain.domain}: verify write failed: #{inspect(reason)}")

        :unchanged

        # coveralls-ignore-stop
    end
  end

  defp land(domain, funnel) do
    case domain
         |> Ash.Changeset.for_update(funnel, %{}, authorize?: false)
         |> Ash.update() do
      {:ok, _updated} ->
        funnel_transition(funnel)

      # coveralls-ignore-start - defensive: same stance as the verify
      # write above — the next tick is the retry
      {:error, reason} ->
        Logger.warning(
          "Access domain #{domain.domain}: #{funnel} write failed: #{inspect(reason)}"
        )

        :unchanged

        # coveralls-ignore-stop
    end
  end

  defp funnel_transition(:mark_failed), do: :failed
  defp funnel_transition(:mark_needs_attention), do: :needs_attention

  # ------------------------------------------------------------------
  # Reads
  # ------------------------------------------------------------------

  defp get_certificate(domain, kubeconfig) do
    config = Application.fetch_env!(:flux_vale, :access_domains)

    Certificate.get(
      kubeconfig,
      Keyword.fetch!(config, :certificate_namespace),
      AccessDomain.certificate_name(domain)
    )
  end

  # The Certificate's Ready condition — "True"/"False"/nil (absent or
  # malformed). Same extraction Certificate.ready_status/3 does, on a
  # body this pass already holds (one GET, not two).
  defp ready(%{"status" => %{"conditions" => conditions}}) when is_list(conditions) do
    Certificate.find_ready(conditions)
  end

  defp ready(_no_status_block), do: nil

  defp secret_ref(%{"spec" => %{"secretName" => name}}) when is_binary(name), do: name

  # coveralls-ignore-next-line - defensive: cert-manager always sets spec.secretName when Ready=True
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
