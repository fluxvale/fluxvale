defmodule FluxVale.Infrastructure.Operations.SetExposure do
  @moduledoc """
  Applies an exposure change to the cluster (#265) — the instant
  kill-switch half of the primitive:

  - **→ private**: delete the public routes first, then tighten the
    namespace NetworkPolicy to same-namespace-only ingress. Routes
    first is fail-closed: with no route, no traffic reaches the
    namespace whatever the policy admits. A failed step compensates
    toward the row's rolled-back (public) posture before returning —
    see `apply_exposure/2`.
  - **→ public**: mint the routes in the row's current mode — wake
    mode for a sleeping instance (so a visitor can wake it), serving
    otherwise — then re-admit the edge in the policy. Failure
    compensates the same way (any minted route is removed again).

  In-cluster paths never notice either direction: panel operations,
  sweeps, backups, and health ride the API server and in-namespace
  workloads, never the edge exception the policy widens or narrows.

  The future access layer (#265's provider-agnostic seam) attaches
  alongside this op — it grants reachability to `:private` rows; it
  must not widen this policy's edge entry.
  """

  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  @policy "default-deny-ingress"

  @doc """
  Applies `instance.exposure` to the cluster. `:ok` when the cluster
  holds the posture; `{:error, reason}` otherwise (the caller — the
  `set_exposure` action — fails the write on it, so the row never
  claims a posture the cluster hasn't reached).
  """
  @spec call(Instance.t()) :: :ok | {:error, term()}
  def call(instance) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance) do
      apply_exposure(kubeconfig, instance)
    end
  end

  # #267 review finding 3: the action fails AND rolls the row back to
  # the pre-toggle exposure, but any cluster write that already landed
  # stays — so each arm compensates toward the posture the row will
  # keep before returning its failure. A compensating step that ALSO
  # fails leaves drift the original error already owns: the action's
  # error return surfaces to the panel, and the owner's retry (or the
  # next deploy) re-converges — there is no silent success here.
  defp apply_exposure(kubeconfig, %{exposure: :private} = instance) do
    with :ok <- EdgeRoutes.apply_private(kubeconfig, instance),
         :ok <- apply_policy(kubeconfig, instance, :private) do
      :ok
    else
      {:error, reason} -> restore_public_edge(kubeconfig, instance, reason)
    end
  end

  defp apply_exposure(kubeconfig, %{exposure: :public, status: status} = instance) do
    mode = if(status == :sleeping, do: :wake, else: :serving)

    with :ok <- apply_routes(kubeconfig, instance, mode),
         :ok <- apply_policy(kubeconfig, instance, :public) do
      :ok
    else
      {:error, reason} -> restore_private_edge(kubeconfig, instance, reason)
    end
  end

  # The row rolls back to :public with its routes deleted — publicly
  # persisted and unreachable, and nothing self-heals it (the
  # reconciler never re-applies routes). Re-mint them (mode by status,
  # the public arm's own rule; apply_public — the record still names
  # :private mid-rollback, so the dispatch must not re-route it). The
  # policy needs no restore: its failed apply left the old,
  # edge-admitting object in place.
  defp restore_public_edge(kubeconfig, instance, reason) do
    mode = if(instance.status == :sleeping, do: :wake, else: :serving)
    _restored = EdgeRoutes.apply_public(kubeconfig, instance, mode)
    {:error, reason}
  end

  # The mirror arm: the row rolls back to :private, so any route
  # minted above must go. No reachability leak either way (the policy
  # still denies the edge until its own apply succeeds) — this is
  # drift cleanup, same retry ownership on its failure.
  defp restore_private_edge(kubeconfig, instance, reason) do
    _removed = EdgeRoutes.apply_private(kubeconfig, instance)
    {:error, reason}
  end

  defp apply_routes(kubeconfig, instance, :wake), do: EdgeRoutes.apply_wake(kubeconfig, instance)

  defp apply_routes(kubeconfig, instance, :serving),
    do: EdgeRoutes.apply_serving(kubeconfig, instance)

  # The spec is built from the INSTANCE, not the exposure atom: it is the
  # one source that preserves an attached gateway's peer (and narrows it
  # to that gateway's pods). Rewriting from the exposure floor alone would
  # delete the gateway entry while the route row and billing survived.
  defp apply_policy(kubeconfig, instance, _target_exposure) do
    case NetworkPolicy.create(
           kubeconfig,
           instance.namespace,
           @policy,
           InstanceK8s.network_policy_spec(instance)
         ) do
      {:ok, _policy} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
