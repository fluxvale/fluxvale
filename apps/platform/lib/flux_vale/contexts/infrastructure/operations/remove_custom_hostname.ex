defmodule FluxVale.Infrastructure.Operations.RemoveCustomHostname do
  @moduledoc """
  The member's custom-address remove (S6): delete the row's edge
  routes first — the public custom route for a public instance (no
  pairing read: the exposure is the whole dispatch), the pairing-gated
  access routes for a private one — then the `InstanceHostname` row,
  then re-render the resolver view best-effort.

  The order is the false-claim discipline in reverse: a route whose row
  is gone would still answer at the edge with no record of why, so the
  routes go while the row still names them. An unattached private
  instance has no routes to remove (the mint skipped the cluster too),
  so the cluster limb is skipped entirely for it.

  The edge limb reads the exposure FRESH under the instance row lock —
  the mint's symmetric serialization (the toggle's too): dispatching
  on the guard read's stale posture could destroy a row whose public
  route a racing private-to-public toggle just minted, orphaning it.

  After the row is gone the remove re-tells the app its remaining
  address (or drops the URL key) best-effort; a failure leaves the old
  value stale-but-working and converges on the next event or deploy.

  Ownership is the authorized hostname read (its policy rides the
  instance's org membership) plus the authorized instance read — a
  foreign row is a not-found before any cluster call (the
  AccessDomain.remove_via_api shape).
  """

  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.Infrastructure.Operations.SyncInstanceUrlEnv
  alias FluxVale.Repo

  require Ash.Query
  require Logger

  @doc """
  `{:ok, hostname}` or `{:error, reason}`. `opts` carry `actor:` /
  `authorize?:` / `context:`.
  """
  @spec call(Ash.UUID.t(), keyword()) :: {:ok, InstanceHostname.t()} | {:error, term()}
  def call(hostname_id, opts \\ []) do
    actor = opts[:actor]
    authorize? = Keyword.get(opts, :authorize?, true)
    read_opts = read_opts(actor, authorize?, opts[:context])

    with {:ok, hostname} <- Ash.get(InstanceHostname, hostname_id, read_opts),
         {:ok, hostname} <- Ash.load(hostname, :access_domain, read_opts),
         :ok <- ensure_custom(hostname.access_domain),
         {:ok, instance} <- Instance.get_by_id(hostname.instance_id, read_opts),
         # The edge limb owns the destroy now — it runs inside the
         # locked transaction, serialized with the unpublish it
         # follows. The re-tell and the render stay after the commit.
         :ok <- remove_edge(instance, hostname, read_opts) do
      # The re-tell runs after the row is destroyed (the derivation
      # must not see the row just removed), before the resolver render.
      tell_app(instance)
      RenderAccessDNS.call()
      {:ok, hostname}
    end
  end

  # The default address's row is load-bearing (the instance's own
  # public/private hostname); removing it would unroute an address the
  # member never chose to lose. The platform row is not member surface
  # (the AccessDomain :remove guard's shape).
  defp ensure_custom(%{kind: :custom}), do: :ok
  defp ensure_custom(%{kind: :platform}), do: {:error, :platform_domain}

  # The edge limb reads the instance FRESH under the row lock — the
  # mint's symmetric (the same serialization the exposure toggle uses
  # across its own applies). The guard read at the top of call/2 may
  # be seconds old: dispatching on it could skip the cluster while a
  # racing private-to-public toggle mints the public route, and the
  # row would die without unpublishing it — an orphan no later walk
  # can name (the T2-F1 class).
  defp remove_edge(instance, hostname, read_opts) do
    case Repo.transaction(fn -> locked_remove_edge(instance.id, hostname, read_opts) end) do
      {:ok, outcome} ->
        outcome

      # coveralls-ignore-start - defensive: the rollback arm of the
      # locked read's DB-outage class (locked_remove_edge), ExUnit
      # cannot stage it (DBConnection reconnects by design).
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  defp locked_remove_edge(instance_id, hostname, read_opts) do
    case lock_row(instance_id) do
      {:ok, %Instance{} = fresh} ->
        unpublish_and_destroy(fresh, hostname, read_opts)

      # Teardown won between the guard read and this lock: nothing to
      # remove — the rows are already gone.
      {:ok, nil} ->
        :ok

      # coveralls-ignore-start - defensive: the locked read's DB-outage
      # class, ExUnit cannot stage it (DBConnection reconnects by
      # design).
      {:error, reason} ->
        Repo.rollback(reason)
        # coveralls-ignore-stop
    end
  end

  # The destroy rides INSIDE the lock — lock -> unpublish -> destroy
  # -> commit. The unserialized destroy was the gap: a toggle (or the
  # idle sweep's sleep/restore/deploy) could take the lock while the
  # hostname row still stood and mint custom-<tail> from it, which the
  # destroy would then orphan (the T2-F1 class). A row that vanished
  # under this remove (a racing double-remove serialized on this very
  # lock) is the goal state already holding — the existence check
  # skips the destroy. A destroy failure returns WITHOUT rolling the
  # landed unpublish back (K8s deletes are not transactional): the
  # error surfaces and the row stands for the retry — everything in
  # the limb is idempotent.
  defp unpublish_and_destroy(fresh, hostname, read_opts) do
    with :ok <- dispatch_edge(fresh, hostname, read_opts) do
      case hostname_row(hostname.id) do
        {:ok, nil} ->
          :ok

        {:ok, row} ->
          destroy(row)

        # coveralls-ignore-start - defensive: the existence check's
        # DB-outage class, ExUnit cannot stage it (DBConnection
        # reconnects by design).
        {:error, reason} ->
          {:error, reason}
          # coveralls-ignore-stop
      end
    end
  end

  # The row lock the exposure toggle holds across its own synchronous
  # cluster applies — the same shape the mint's dispatch and
  # SyncInstanceUrlEnv serialize on.
  defp lock_row(instance_id) do
    Instance
    |> Ash.Query.filter(id == ^instance_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  # A never-deployed instance never minted a route — record-only on
  # the mint's side, record-only on the remove's: the delete-by-name
  # would 404-tolerate anyway, but the gate makes the contract
  # explicit instead of accidental (the same shape bda81d4a gave the
  # mint).
  defp dispatch_edge(%{namespace: nil}, _hostname, _read_opts), do: :ok

  # Public: the custom route lives on the public entrypoint, so the
  # public none limb takes it down — no pairing read (a stale
  # AccessRoute row must not detour the delete). The route goes BEFORE
  # the row destroy — call/2's order — while the row still names the
  # objects: a row destroyed under a standing route can never be named
  # by any later walk (the orphan a gate-2 finding proved survives even
  # a later exposure flip).
  defp dispatch_edge(%{exposure: :public} = fresh, hostname, _read_opts) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(fresh) do
      EdgeRoutes.apply_public_none_for_hostname(kubeconfig, fresh, hostname)
    end
  end

  defp dispatch_edge(fresh, hostname, read_opts) do
    case AccessRoute.get_by_instance(fresh.id, read_opts) do
      {:ok, _route} ->
        with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(fresh) do
          EdgeRoutes.apply_access_none_for_hostname(kubeconfig, fresh, hostname)
        end

      {:error, error} ->
        if route_missing?(error) do
          :ok
        else
          {:error, error}
        end
    end
  end

  # The locked limb's existence check — under the instance lock the
  # row cannot vanish between this read and the destroy (every
  # destroyer serializes here), so a found row is destroyed and a nil
  # is the goal state already holding.
  defp hostname_row(hostname_id) do
    InstanceHostname
    |> Ash.Query.filter(id == ^hostname_id)
    |> Ash.read_one(authorize?: false)
  end

  # authorize?: false — the ownership fence was the authorized reads
  # above (the instance delete stance); the row destroy itself is
  # system-only by policy. A failure passes through: the unpublish
  # already landed (K8s deletes are not transactional) and the row
  # stands for the retry.
  defp destroy(hostname), do: InstanceHostname.destroy(hostname, authorize?: false)

  # Best-effort re-tell: the address is gone either way, so a sync
  # failure is one warning and the remove still succeeds — the app's
  # env is stale-but-working and the delivery-aware retry converges on
  # the next event or deploy. Never an error from the remove.
  defp tell_app(instance) do
    case SyncInstanceUrlEnv.call(instance) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "instance address env sync after remove refused instance=#{instance.id} " <>
            "reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp route_missing?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{resource: AccessRoute}, &1))
  end

  defp route_missing?(_other), do: false

  defp read_opts(actor, authorize?, nil), do: [actor: actor, authorize?: authorize?]

  defp read_opts(actor, authorize?, context) do
    [actor: actor, authorize?: authorize?, context: context]
  end
end
