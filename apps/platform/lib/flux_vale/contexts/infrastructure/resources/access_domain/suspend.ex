defmodule FluxVale.Infrastructure.AccessDomain.Suspend do
  @moduledoc """
  The zero-balance ladder's domain arm (ADR-0040 §11): the honest-dark
  demotion of a serving custom domain. The row lands `:suspended`
  through the one funnel, and BOTH tails of the domain's service go
  dark with it:

  - the edge routes: `EdgeRoutes.apply_access_none_for_domain/3` per
    attached instance — domain-scoped, so the instance's other
    hostnames keep serving (the limb the verify pass reserved for this
    writer), and
  - the tailnet claim: the S3 remove's unclaim limb (split-DNS route
    reverted per the provider's shared-tailnet rule, the gateway's
    `dns_claims` entry dropped) — the SAME helper `RemoveAccessDomain`
    runs, reused not duplicated.

  **Failure of a side effect fails the suspension** (fail-closed): the
  row keeps its state and keeps accruing, and the next sweep pass
  RE-RUNS THE WHOLE DOMAIN — the arms are idempotent (safe-deletes; an
  idempotent provider unclaim), so re-entry converges on the full dark
  posture instead of retrying a residual. Honest about the partial
  case: a pass that removed the routes but failed the unclaim leaves
  the domain HALF dark while still accruing — one sweep cadence of
  mismatch is the price of never demoting a row whose tails are not
  both down, and the log line is the trace.

  The anchor parks on the way down (the gateway Suspend stance): the
  suspended interval cannot bill on resume. The Certificate and its
  namespace replicas stay — a resume re-mints the routes; nothing is
  re-issued.

  **The CoreDNS render is success-only, post-commit** (the S4 lesson,
  the resume's mirror): the unclaim drops the domain's claims entry
  inside this transaction, and the view must stop answering it only
  once that write has committed — a failed suspension leaves the
  previous view standing, exactly as the row left it.

  **Ordering is the resume fix's principle in mirror** (the
  irreversible write first): the tailnet unclaim is the one write no
  transaction can roll back, so it runs BEFORE the edge removal. An
  unclaim failure then fails the suspension AS A UNIT — the verified
  domain stays fully serving, nothing half-dark. A route-removal
  failure after a successful unclaim leaves the claimed-but-unrouted
  shape — dark by resolution (the split-DNS route is gone, §8-honest)
  while the row still stands `:verified` and accrues — and the sweep's
  whole-domain re-entry converges the rest (the removals are
  404-tolerant). Side effects first (`before_action`), the row write
  second — a failed row write after successful side effects self-heals
  because the ladder keeps selecting serving rows at ≤ 0 and re-enters
  (the gateway Resume moduledoc owns the full argument; the arms are
  idempotent, so the re-entry is a no-op on the cluster side).
  """

  use Ash.Resource.Change

  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.RemoveAccessDomain
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.Infrastructure.Operations.VerifyAccessDomains

  require Logger

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    # The render hook registers in the CHANGE phase: hooks added inside
    # a before_action callback are not on the changeset the engine
    # hands to after_transaction (the resume's note).
    changeset
    |> Ash.Changeset.after_transaction(fn _changeset, result ->
      case result do
        {:ok, _suspended} -> RenderAccessDNS.call()
        {:error, _reason} -> :ok
      end

      result
    end)
    |> Ash.Changeset.before_action(fn changeset ->
      domain = changeset.data

      # Idempotent: the ladder re-enters this arm every pass while the
      # balance stays ≤ 0. A row already parked has nothing to do —
      # and a :pending/:failed row never served, so there is nothing
      # to demote either; a :platform row never bills at all (§11) and
      # must never be demoted by a money event. The ladder's query
      # selects serving `:custom` rows only — these guards are the
      # belt behind it.
      if domain.state in [:suspended, :pending, :failed] or domain.kind == :platform do
        changeset
      else
        suspend(domain, changeset)
      end
    end)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (cluster I/O in the hook)
  def atomic?, do: false

  defp suspend(domain, changeset) do
    with {:ok, kubeconfig} <- K8s.kubeconfig(),
         :ok <- unclaim_tailnet_state(domain),
         :ok <- remove_edge_routes(kubeconfig, domain) do
      changeset
      |> Ash.Changeset.force_change_attribute(:state, :suspended)
      |> Ash.Changeset.force_change_attribute(:metering_since, nil)
    else
      {:error, reason} ->
        Logger.error("Access domain #{domain.domain} suspend failed: #{inspect(reason)}")

        Ash.Changeset.add_error(changeset, message: "Couldn't suspend domain")
    end
  end

  # Domain-scoped honest dark: only THIS domain's routes come down.
  # The first failure stops the walk (fail-closed — the sweep retries;
  # a half-removed set re-converges on re-entry, the deletes are
  # 404-tolerant).
  defp remove_edge_routes(kubeconfig, domain) do
    domain
    |> VerifyAccessDomains.serving_instances()
    |> Enum.reduce_while(:ok, fn instance, :ok ->
      case EdgeRoutes.apply_access_none_for_domain(kubeconfig, instance, domain) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp unclaim_tailnet_state(domain) do
    case RemoveAccessDomain.unclaim_tailnet_state(domain) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unclaim_failed, reason}}
    end
  end
end
