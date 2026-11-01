defmodule FluxVale.Infrastructure.AccessDomain.Resume do
  @moduledoc """
  The owner's funded resume after a balance suspension (ADR-0040 §11):
  the row back to `:verified`, the accrual window reopened, and — row
  committed — the two tails of the domain's service re-armed:

  - the edge routes, re-minted per instance for its CURRENT status
    (the verify pass's promotion limb, entered for the same population
    the suspension stripped), FIRST, and
  - the tailnet claim, through the claim operation's provider path
    (`Infrastructure.claim_access_domain/3` — the same gates, claims
    funnel and P2-3 retry the member-scoped claim runs), LAST.

  **The order is the danger ordering.** The routes are local cluster
  writes (SSA-idempotent, converged by the retry); the tailnet claim is
  EXTERNAL state no transaction can roll back. A failure in the routes
  aborts the resume before the tailnet is ever touched — the API never
  sees a half-resume. The reverse order would claim split-DNS for a
  domain whose route mints then failed: names that resolve on the
  tailnet into nothing.

  Routes standing WITHOUT the claim (the failure window here: routes
  minted, claim refused) are the safe dangle — a hostname with no
  split-DNS route does not resolve on the tailnet, so nothing is
  reachable; the owner's retry converges the claim and the pair is
  whole again. This is `RemoveAccessDomain`'s hard-failure stance in
  the opposite direction: there, an unclaim failure FAILS the remove
  because a removed row can never record what to revert — here the row
  still stands (`:suspended` after the rollback), so the retry owns the
  convergence and nothing is stranded ungoverned.

  The anchor reopens at `now` — the suspended interval is not billed
  (Suspend parked it), and the resume starts a fresh accrual window.

  **Ordering is load-bearing: the row commits before the cluster work**
  (the gateway Resume's discipline). The re-mint and the re-claim run
  in `after_action`, so a failure aborts the action and rolls the row
  back to `:suspended` — nothing serving, nothing billed, owner can
  retry. Cluster-first would be the opposite hazard: a row write that
  then failed would leave `:suspended` while the hostnames answered,
  and NOTHING retries that — the ladder skips `:suspended` and the
  observer writes over neither `:suspended` nor `:failed`, so the
  domain would serve free forever.

  **The CoreDNS render is success-only, post-commit.** The claim
  operation runs nested inside this transaction (its `render: false`
  opt suppresses its own render), so the claims write is uncommitted
  until this action commits — rendering inside would put uncommitted
  claims into the ConfigMap (the S4 lesson). This module renders in
  `after_transaction`, on the `{:ok, _}` branch only: a failed resume
  leaves the previous view standing, exactly as the row left it.

  **The token drift (the S3 shape):** a claim the tailnet refuses —
  `:unauthorized`, `:forbidden`, or a MISSING token (`:no_api_token`) —
  drifts the GATEWAY row `:needs_attention` with the honest copy (the
  same `:update_state` funnel the claim operation writes: the
  provider's copy for a rejected key, this module's for a missing one)
  AND fails the resume honestly. All three kinds are this module's
  `@token_drift_kinds`, and all three drift through the same
  `after_transaction` write — the claim operation's own nested 401/403
  drift dies with the rollback, so this module's write is the one that
  persists. The row stays `:suspended` and the owner pastes a fresh
  token and retries. No silent half-serve.

  **A parked gateway refuses the resume** (`:gateway_not_serving`, the
  claim operation's own gate): arming routes toward a scaled-to-zero
  tunnel would serve a dead tailnet address. The owner resumes the
  gateway first, then the domain.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.RemoveAccessDomain
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.Infrastructure.Operations.VerifyAccessDomains

  require Logger

  # The one honest copy the provider does not own (Tailscale carries
  # the REJECTED-key copy; a MISSING key has no provider verdict to
  # quote — this module owns it, the constants rule).
  @missing_token_message "Your Tailscale API key is missing — paste one to reconnect access"

  # The drift kind threads from the after_action hook to the
  # after_transaction hook through the process dictionary: both run on
  # this process in order, the key is unique to this module, and the
  # value is read only to act on it. (A failed after_action cannot
  # carry context out — Ash discards the mutated changeset — and the
  # drift must SURVIVE the rollback, so it cannot ride the error.)
  @drift_key :access_domain_resume_token_drift

  @token_drift_kinds [:no_api_token, :unauthorized, :forbidden]

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    # The drift hook registers in the CHANGE phase: hooks added inside
    # a before_action callback are not on the changeset the engine
    # hands to after_transaction (the instance SetExposure precedent
    # registers there for the same reason).
    changeset
    |> Ash.Changeset.after_transaction(fn changeset, result ->
      settle_down(changeset.data, result)
    end)
    |> Ash.Changeset.before_action(fn changeset ->
      domain = changeset.data

      # Only a suspended domain resumes; a double-click is a no-op,
      # not a second claim.
      if domain.state == :suspended do
        resume(changeset)
      else
        changeset
      end
    end)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (cluster I/O in the hook)
  def atomic?, do: false

  defp resume_error do
    InvalidAttribute.exception(field: :state, message: "Couldn't resume domain")
  end

  # Row first, cluster second (see the moduledoc). `after_action`
  # returning an error rolls the row's own write back, so a failed
  # re-claim or re-mint leaves the domain exactly as it was. (The
  # after_transaction half is registered up in `change/2` — see the
  # note there.)
  defp resume(changeset) do
    changeset
    # The gateway Resume's expected-state pattern: the UPDATE lands
    # only on a still-:suspended row, so a concurrent writer (a second
    # resume, a removal) turns this write into a StaleRecord instead
    # of a blind overwrite — the after_action cluster work never runs
    # on a row we didn't win, and the anchor cannot restart twice.
    |> Ash.Changeset.filter(state: :suspended)
    |> Ash.Changeset.force_change_attribute(:state, :verified)
    |> Ash.Changeset.force_change_attribute(:metering_since, DateTime.utc_now())
    |> Ash.Changeset.after_action(fn _changeset, resumed ->
      case reclaim_and_rearm(resumed) do
        :ok ->
          {:ok, resumed}

        {:error, reason} ->
          Logger.error("Access domain #{resumed.domain} resume failed: #{inspect(reason)}")
          remember_drift_kind(reason)
          {:error, resume_error()}
      end
    end)
  end

  # Nothing attached — nothing ever resolved this domain on the
  # tailnet, so there is no claim to restore and no routes to re-mint:
  # the unclaim's no-gateway stance, mirrored. The selector is the
  # verify pass's (one owner, three consumers).
  defp reclaim_and_rearm(domain) do
    case VerifyAccessDomains.serving_instances(domain) do
      [] -> :ok
      instances -> reclaim_then_rearm(domain, instances)
    end
  end

  # Routes FIRST, claim LAST — the danger ordering (see the
  # moduledoc): the claim is the one write no transaction can roll
  # back, so every local failure must be exhausted before the tailnet
  # is touched. `render: false` — this transaction's claims write is
  # uncommitted until the action commits; the render is this module's,
  # post-commit, success-only.
  defp reclaim_then_rearm(domain, instances) do
    with {:ok, kubeconfig} <- K8s.kubeconfig(),
         {:ok, gateway} <- org_gateway(domain),
         :ok <- rearm_routes(kubeconfig, instances),
         {:ok, _row} <-
           Infrastructure.claim_access_domain(gateway, domain,
             authorize?: false,
             render: false
           ) do
      :ok
    end
  end

  defp org_gateway(domain) do
    case AccessGateway.get_for_organization(domain.organization_id, authorize?: false) do
      {:ok, %AccessGateway{} = gateway} ->
        {:ok, gateway}

      # Attached instances without a gateway row cannot exist (the
      # pairing FKs); anything but the not-found shape is a failure
      # that must abort the resume, not be eaten.
      {:error, error} ->
        if RemoveAccessDomain.gateway_missing?(error) do
          {:error, :no_gateway}
        else
          {:error, error}
        end
    end
  end

  # Fail-closed: a failed re-mint fails the resume (the row rolls back
  # to :suspended and the owner retries); the mints are SSA-idempotent,
  # so re-entry converges.
  defp rearm_routes(kubeconfig, instances) do
    Enum.reduce_while(instances, :ok, fn instance, :ok ->
      case rearm_instance(kubeconfig, instance) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp rearm_instance(kubeconfig, instance) do
    with {:ok, route} <- AccessRoute.get_by_instance(instance.id, authorize?: false),
         {:ok, route} <- Ash.load(route, :gateway, authorize?: false) do
      EdgeRoutes.apply_access_for_status(kubeconfig, route.gateway, instance)
    end
  end

  defp remember_drift_kind(reason) when reason in @token_drift_kinds do
    Process.put(@drift_key, reason)
  end

  defp remember_drift_kind(_other), do: :ok

  # The two post-transaction duties, in one hook (both must see the
  # action's FINAL outcome):
  #
  # - the S3 drift, persisted outside the rolled-back transaction. Any
  #   non-token failure drifts nothing (the claim operation's stance:
  #   only the token reasons present as "the owner must act");
  # - the CoreDNS render, on the {:ok, _} branch ONLY — the claims
  #   write committed with this action, so this is the first point
  #   where the ConfigMap may learn of it (uncommitted claims must
  #   never reach the view — the S4 lesson). A failed resume leaves
  #   the previous view standing, exactly as the row left it.
  defp settle_down(domain, result) do
    result =
      case Process.get(@drift_key) do
        nil ->
          result

        kind ->
          Process.delete(@drift_key)
          drift_gateway_token_failure(domain, kind)
          result
      end

    case result do
      {:ok, _row} ->
        RenderAccessDNS.call()
        result

      {:error, _reason} ->
        result
    end
  end

  defp drift_gateway_token_failure(domain, kind) do
    with {:ok, %AccessGateway{} = gateway} <-
           AccessGateway.get_for_organization(domain.organization_id, authorize?: false) do
      message = token_failure_message(gateway, kind)

      case AccessGateway.update_state(
             gateway,
             %{
               state: :needs_attention,
               status_message: message,
               needs_attention_since: DateTime.utc_now()
             },
             authorize?: false
           ) do
        {:ok, _row} ->
          :ok

        # Never fail the resume over its own drift write — the row's
        # failure is the owner's signal; the copy is best-effort (the
        # claim operation's stance for its own drift).
        {:error, reason} ->
          Logger.warning(
            "Access domain #{domain.domain}: token-drift write failed: #{inspect(reason)}"
          )

          :ok
      end
    end
  end

  defp token_failure_message(_gateway, :no_api_token), do: @missing_token_message

  defp token_failure_message(gateway, kind) do
    AccessProvider.impl_for(gateway).token_drift_message(kind)
  end
end
