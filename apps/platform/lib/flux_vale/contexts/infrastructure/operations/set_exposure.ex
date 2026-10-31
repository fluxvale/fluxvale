defmodule FluxVale.Infrastructure.Operations.SetExposure do
  @moduledoc """
  Applies an exposure change to the cluster (#265) — the instant
  kill-switch half of the primitive:

  - **→ private**: mint the attached pairing's access arms (ADR-0040
    §8) first — an attached instance must be reachable on its hostnames
    before the public route goes dark — then delete the public routes,
    then tighten the namespace NetworkPolicy. Routes first is
    fail-closed: with no route, no traffic reaches the namespace
    whatever the policy admits. A failed step compensates toward the
    row's rolled-back (public) posture before returning — see
    `apply_exposure/2`.
  - **→ public**: mint the routes in the row's current mode — wake
    mode for a sleeping instance (so a visitor can wake it), serving
    otherwise — then re-admit the edge in the policy, then remove the
    access arms (a public posture holds none). Failure compensates the
    same way (any minted route is removed again).

  In-cluster paths never notice either direction: panel operations,
  sweeps, backups, and health ride the API server and in-namespace
  workloads, never the edge exception the policy widens or narrows.

  The access layer rides this op (ADR-0040 §8, as amended): going
  private mints an attached pairing's access arms and the widened
  policy edge admission (Amendment 1); going public removes them. The
  compensators restore both planes — a rolled-back row is never dark on
  its private hostnames.
  """

  alias Ash.Error.Invalid
  alias Ash.Error.Query.NotFound
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Infrastructure.AccessRoute
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
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance),
         :ok <- precheck_access_namespace(instance) do
      apply_exposure(kubeconfig, instance)
    end
  end

  # Attached instances reach the namespace resolver inside apply_policy
  # — AFTER edge writes whose compensators below only handle error
  # tuples, so a raise there unwinds past them and strands exactly the
  # drift they exist to prevent. Resolve EAGERLY, before the first
  # write. Unattached instances never reach the resolver; their
  # exposure must not fail on access-gateway config. A read FAILURE is
  # not "not attached" — fail the exposure rather than proceed with the
  # precheck silently void (configure_backups' NotFound split is the
  # precedent for telling a miss from an outage).
  defp precheck_access_namespace(%Instance{id: id}) do
    case AccessRoute.get_by_instance(id, authorize?: false) do
      {:ok, _route} ->
        resolve_access_namespace()

      {:error, %Invalid{errors: errors}} ->
        split_read_error(errors)

      # coveralls-ignore-start - defensive: the only other read failure is
      # a DB outage, which ExUnit cannot simulate (configure_backups'
      # NotFound split is the precedent for this shape).
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  defp resolve_access_namespace do
    InstanceK8s.gateway_access_namespace()
    :ok
  end

  defp split_read_error(errors) do
    if Enum.any?(errors, &match?(%NotFound{}, &1)) do
      :ok
    else
      # coveralls-ignore-start - defensive: a non-NotFound Invalid from
      # this read is the same DB-outage class as the arm above.
      {:error, %Invalid{errors: errors}}
      # coveralls-ignore-stop
    end
  end

  # #267 review finding 3: the action fails AND rolls the row back to
  # the pre-toggle exposure, but any cluster write that already landed
  # stays — so each arm compensates toward the posture the row will
  # keep before returning its failure. A compensating step that ALSO
  # fails leaves drift the original error already owns: the action's
  # error return surfaces to the panel, and the owner's retry (or the
  # next deploy) re-converges — there is no silent success here.
  #
  # The access limbs (ADR-0040 §8): going private mints the access arms
  # FIRST (an attached instance must be reachable on its hostnames
  # before the public route goes dark — no neither-works window), then
  # the existing public deletes; going public removes them after the
  # public mint lands (the public posture has no access arms). A failed
  # access mint compensates like any failed limb: the arms come back
  # off in the restore before the error returns.
  defp apply_exposure(kubeconfig, %{exposure: :private} = instance) do
    with :ok <- maybe_access_mint(kubeconfig, instance),
         :ok <- EdgeRoutes.apply_private(kubeconfig, instance),
         :ok <- apply_policy(kubeconfig, instance, :private) do
      :ok
    else
      {:error, reason} -> restore_public_edge(kubeconfig, instance, reason)
    end
  end

  defp apply_exposure(kubeconfig, %{exposure: :public, status: status} = instance) do
    mode = if(status == :sleeping, do: :wake, else: :serving)

    with :ok <- apply_routes(kubeconfig, instance, mode),
         :ok <- apply_policy(kubeconfig, instance, :public),
         :ok <- EdgeRoutes.apply_access_none(kubeconfig, instance) do
      :ok
    else
      {:error, reason} -> restore_private_edge(kubeconfig, instance, reason)
    end
  end

  # Attached rows mint their access arms per current status via the one
  # owner (EdgeRoutes.apply_access_for_status). Unattached private is
  # panel-only: nothing to mint, no cluster calls.
  defp maybe_access_mint(kubeconfig, instance) do
    case AccessRoute.get_by_instance(instance.id, authorize?: false) do
      {:ok, route} ->
        with {:ok, route} <- Ash.load(route, :gateway, authorize?: false) do
          EdgeRoutes.apply_access_for_status(kubeconfig, route.gateway, instance)
        end

      {:error, error} ->
        # A read FAILURE is not "unattached" (the sleep-path split):
        # fail the toggle rather than strand the row dark-by-accident.
        if access_route_missing?(error), do: :ok, else: {:error, error}
    end
  end

  defp access_route_missing?(%Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%NotFound{}, &1))
  end

  # A non-NotFound shape must never read as "unattached" — the toggle
  # would strand a paired instance panel-only. Pinned by the forced
  # read-boom test below.
  defp access_route_missing?(_other), do: false

  # The row rolls back to :public with its routes deleted — publicly
  # persisted and unreachable, and nothing self-heals it (the
  # reconciler never re-applies routes). Re-mint them (mode by status,
  # the public arm's own rule; apply_public — the record still names
  # :private mid-rollback, so the dispatch must not re-route it). The
  # access arms minted before the failure come back OFF first: a public
  # row holds none. The policy needs no restore: its failed apply left
  # the old, edge-admitting object in place.
  defp restore_public_edge(kubeconfig, instance, reason) do
    _removed = EdgeRoutes.apply_access_none(kubeconfig, instance)

    mode = if(instance.status == :sleeping, do: :wake, else: :serving)
    _restored = EdgeRoutes.apply_public(kubeconfig, instance, mode)
    {:error, reason}
  end

  # The mirror arm: the row rolls back to :private, so any route minted
  # above must go — AND the access arms the public limb deleted must
  # come back: a partial delete that rolled the row back private must
  # not leave it dark on both planes (§8's forbidden window). No
  # reachability leak either way (the policy still denies the edge
  # until its own apply succeeds) — this is drift cleanup, same retry
  # ownership on its failure.
  defp restore_private_edge(kubeconfig, instance, reason) do
    _removed = EdgeRoutes.apply_private(kubeconfig, instance)
    _reminted = maybe_access_mint(kubeconfig, instance)
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
