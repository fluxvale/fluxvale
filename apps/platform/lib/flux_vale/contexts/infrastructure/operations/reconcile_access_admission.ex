defmodule FluxVale.Infrastructure.Operations.ReconcileAccessAdmission do
  @moduledoc """
  The access edge's one-minute admission pass (ADR-0040 Am. 6): a
  gateway's pod can move at any moment, no row records its address, and
  the access routes match it — so this pass re-reads every paired
  gateway's current pod address and re-applies the arms of its attached
  private instances when the address moved.

  Each gateway's last-converged source lives in the `Edge.Activity`
  memo, in memory on purpose (the routes are the record). Three states
  plus `nil`: an address string (converged on that address), `:none`
  (converged on "no running pod" — the routes stay withheld), `:dirty`
  (the last re-apply failed — the next pass retries the whole set), and
  `nil` (never converged here — a restart empties the memo and every
  paired gateway re-applies once).

  `:destroying` gateways are skipped: the teardown removes the arms
  itself, first of all, and must not race a re-mint. `:suspended` is
  NOT skipped — its routes are withheld by this pass (a suspended
  gateway has no running pod to admit from). A pairing that ends under
  the pass (a teardown or a detach won the race) has the arms it just
  applied removed again: a teardown writes `:destroying` before it
  removes the arms, so one of the two orders always wins.

  The fail-closed posture: a failed pod read decides nothing (the memo
  keeps its previous answer and the next pass re-reads), a failed
  instance apply leaves the memo `:dirty`, and a restart empties the
  memo so every paired gateway re-applies once.

  Steady state is one pod list per paired gateway per minute and no
  writes.
  """

  alias FluxVale.Clients.K8s
  alias FluxVale.Edge.Activity
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS

  require Ash.Query
  require Logger

  @doc """
  `{:ok, %{checked: n, converged: m}}` — every paired gateway examined,
  and how many converged this pass (their memo became an address or
  `:none`; a `:dirty` result and a failed pod read count for neither).
  `{:error, term()}` only when the platform cluster is unreachable —
  the job fails and Oban retries.
  """
  @spec call(keyword()) ::
          {:ok, %{checked: non_neg_integer(), converged: non_neg_integer()}}
          | {:error, term()}
  def call(_opts \\ []) do
    with {:ok, kubeconfig} <- K8s.kubeconfig() do
      paired = paired_gateways()
      prune_stale_memo(paired)

      {checked, converged} = tally(paired, kubeconfig)

      # The resolver's views key on the gateway's pod address, so a
      # convergence re-renders them — once per pass, best-effort like
      # every render call (a failure leaves the previous view standing).
      if converged > 0, do: RenderAccessDNS.call()

      {:ok, %{checked: checked, converged: converged}}
    end
  end

  defp tally(paired, kubeconfig) do
    Enum.reduce(paired, {0, 0}, fn gateway, {checked, converged} ->
      case admit(kubeconfig, gateway) do
        :converged -> {checked + 1, converged + 1}
        _unchanged_or_failed -> {checked + 1, converged}
      end
    end)
  end

  # The system seam (`authorize?: false` — the pass runs actorless, the
  # platform's read of its own pairing). :destroying is skipped: the
  # teardown removes the arms itself, first of all, and must not race a
  # re-mint. :suspended is not skipped — its routes are withheld by
  # this pass (no running pod → :none).
  defp paired_gateways do
    AccessRoute
    |> Ash.Query.load(:gateway)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.gateway)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&(&1.state == :destroying))
  end

  # A memo entry must not outlive its pairing: gateway ids are never
  # reused, so forgetting an id that is no longer paired is always safe.
  defp prune_stale_memo(paired) do
    paired_ids = MapSet.new(paired, & &1.id)

    Activity.admitted_source_ids()
    |> Enum.reject(&MapSet.member?(paired_ids, &1))
    |> Enum.each(&Activity.forget_admitted_source/1)
  end

  # The gateway's CURRENT pod address decides the target: the address
  # string to admit from, or `:none` when no pod is running (the arms
  # come down; EdgeRoutes owns the withholding). A read that FAILED
  # decides nothing — the memo keeps its previous answer and the next
  # pass re-reads (fail-closed).
  defp admit(kubeconfig, gateway) do
    case InstanceK8s.gateway_pod_ip(kubeconfig, gateway) do
      {:ok, ip} ->
        converge(gateway, ip)

      {:error, :no_running_pod} ->
        converge(gateway, :none)

      {:error, reason} ->
        Logger.warning(
          "Access edge: gateway #{gateway.id} address read failed: #{inspect(reason)}"
        )

        :failed
    end
  end

  defp converge(gateway, target) do
    if Activity.admitted_source(gateway.id) == target do
      # Already converged on this source: the arms stand as applied.
      :unchanged
    else
      instances = eligible_instances(gateway)
      results = Enum.map(instances, &reapply(gateway, &1))

      if Enum.all?(results, &(&1 == :ok)) do
        Activity.remember_admitted_source(gateway.id, target)

        Logger.info(
          "Access edge: gateway #{gateway.id} admitted source is now #{inspect(target)}"
        )

        :converged
      else
        # The next pass retries the whole set: :dirty differs from every
        # target, and the successful applies are idempotent (SSA).
        Activity.remember_admitted_source(gateway.id, :dirty)
        :failed
      end
    end
  end

  # Only private instances with a namespace hold access arms: the
  # pairing row outlives a flip to public (a public instance's toggle
  # removed its arms), and an instance with no namespace has nothing to
  # route into.
  defp eligible_instances(gateway) do
    gateway
    |> AccessGateway.attached_instances()
    |> Enum.filter(&(&1.exposure == :private and not is_nil(&1.namespace)))
  end

  # One instance's arms, per the row's CURRENT status, on the instance's
  # own kubeconfig (the attach/wake-controller pattern). The read runs
  # the system seam too (`authorize?: false` — actorless pass).
  defp reapply(gateway, instance) do
    case InstanceK8s.kubeconfig_for(instance) do
      {:ok, instance_kubeconfig} ->
        arm(instance_kubeconfig, gateway, instance)

      {:error, reason} ->
        Logger.warning(
          "Access edge: gateway #{gateway.id} — kubeconfig read failed for instance " <>
            "#{instance.id}: #{inspect(reason)}"
        )

        :failed
    end
  end

  defp arm(instance_kubeconfig, gateway, instance) do
    case Instance.get_by_id(instance.id, authorize?: false) do
      {:ok, fresh} ->
        case EdgeRoutes.apply_access_for_status(instance_kubeconfig, gateway, fresh) do
          :ok ->
            maybe_recheck(instance_kubeconfig, gateway, fresh)

          {:error, reason} ->
            log_reapply_failed(gateway, instance, reason)
            :failed
        end

      # coveralls-ignore-start - race only: the row vanished under the
      # pass (teardown won between the pairing read and this read); the
      # pairing row dies with it, so there is no arm left to re-point.
      {:error, _gone} ->
        :ok
        # coveralls-ignore-stop
    end
  end

  # The last-writer guard (the attach's reapply_if_status_moved shape):
  # the apply decided from the row it read; a sleep or wake committing
  # between that read and the apply would make this pass's write the
  # stale one. Re-read once after `:ok` — a moved status re-applies with
  # the fresh row; a vanished row is the race lost to teardown.
  defp maybe_recheck(instance_kubeconfig, gateway, applied) do
    case Instance.get_by_id(applied.id, authorize?: false) do
      {:ok, %{status: status} = fresh} when status != applied.status ->
        case EdgeRoutes.apply_access_for_status(instance_kubeconfig, gateway, fresh) do
          :ok ->
            undo_if_ended(instance_kubeconfig, gateway, fresh)

          {:error, reason} ->
            log_reapply_failed(gateway, applied, reason)
            :failed
        end

      {:ok, _status_stable} ->
        undo_if_ended(instance_kubeconfig, gateway, applied)

      # coveralls-ignore-start - race only: the row vanished under the
      # pass (teardown won); there is no arm left to re-point.
      {:error, _gone} ->
        :ok
        # coveralls-ignore-stop
    end
  end

  # The teardown guard: the pass decided from a pairing read made moments
  # ago. A teardown that began since writes `:destroying` FIRST and removes
  # the arms next, so this read catches either order. No pairing row is
  # the same answer (a detach won): nothing is left to route.
  defp pairing_admits?(gateway_id, instance_id) do
    result =
      AccessRoute
      |> Ash.Query.filter(gateway_id == ^gateway_id and instance_id == ^instance_id)
      |> Ash.Query.load(:gateway)
      |> Ash.read_one(authorize?: false)

    case result do
      # Ash.read_one answers {:ok, row} (or {:ok, nil} / {:error, _} —
      # no pairing, or gone mid-read, is the same "ended" answer).
      {:ok, %{gateway: %{state: state}}} -> state != :destroying
      _ended -> false
    end
  end

  # Runs after an instance's LAST successful apply. A pairing that ended
  # under the pass leaves the arms just applied as orphans, so they are
  # removed again. Its result is the instance's result.
  defp undo_if_ended(kubeconfig, gateway, instance) do
    if pairing_admits?(gateway.id, instance.id) do
      :ok
    else
      Logger.warning(
        "Access edge: gateway #{gateway.id} — pairing ended under the pass, removing the " <>
          "arms just applied for instance #{instance.id}"
      )

      EdgeRoutes.apply_access_none(kubeconfig, instance)
    end
  end

  defp log_reapply_failed(gateway, instance, reason) do
    Logger.warning(
      "Access edge: gateway #{gateway.id} — access re-apply failed for instance " <>
        "#{instance.id}: #{inspect(reason)}"
    )
  end
end
