defmodule FluxVale.Infrastructure.AccessGateway.PerformTeardown do
  @moduledoc """
  Opt-out teardown (ADR-0039 §5): detach every attached instance, delete
  the gateway's cluster objects, hard-delete the row.

  Detach-first is the contract: each detach returns its instance's
  NetworkPolicy to the private floor and rewrites the serve config, so
  no instance is ever left pointing at a gateway that no longer exists.
  The provider's `teardown_gateway/1` does that and then deletes the
  objects; this module runs it, then the row. Each detached instance's
  running app is re-told its URL env AFTER the transaction commits —
  the pairing rows and the row itself are gone by then, so the
  derivation answers the post-teardown state and the sync removes or
  changes the URL key (best-effort, warn-only).

  Failure posture (the instance teardown's): return the error so Oban
  retries; `mark_teardown_error` parks the row in `:destroying` with its
  objects intact — a retry can finish what the first attempt started.
  Not `:needs_attention`: the `:observe` and `:settle` triggers both select
  that state, so a failed removal would be re-observed as a live gateway and
  start billing the org that just opted out.

  **Write-off policy:** the final partial interval since the last settle tick
  is not billed (see `Suspend` for the reasoning — the same policy, the same
  reason).
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProvider
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.SyncInstanceUrlEnv

  require Logger

  # The re-tell population rides the process dictionary from the
  # after_action hook to the after_transaction hook: both run on this
  # process in order, the key is unique to this module, and the value
  # is read only to act on it (the instance UpdateEnv and the domain
  # Resume precedent). The capture happens in the transaction, while
  # the pairing rows still exist; the re-tell itself must run
  # post-commit — inside the transaction the derivation's DB inputs
  # were unchanged, so a sync there computed no change while doing
  # cluster I/O under the row lock.
  @retell_key :access_gateway_teardown_retell

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    # The re-tell hook registers in the CHANGE phase: hooks added inside
    # the after_action callback are not on the changeset the engine
    # hands to after_transaction (the domain Resume precedent registers
    # there for the same reason).
    changeset
    |> Ash.Changeset.after_transaction(&post_commit_retell/2)
    |> Ash.Changeset.after_action(&teardown/2)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (cluster I/O in the hook)
  def atomic?, do: false

  defp teardown(_changeset, gateway) do
    provider = AccessProvider.impl_for(gateway)

    # The re-tell population FIRST, while the pairing rows still exist
    # (they and the row die below; the re-tell reads the post-commit
    # world through the after_transaction hook).
    instances = AccessGateway.attached_instances(gateway)
    Process.put(@retell_key, instances)

    # The access edge's arms go FIRST (ADR-0040 §7's caller list): the
    # host-keyed routes live in the INSTANCE namespaces, outside the
    # provider's own teardown reach — removing them before the gateway
    # dies means no hostname keeps answering through a tunnel that is
    # being torn down. Idempotent, so a retry converges a partial pass.
    with :ok <- remove_access_arms(instances) do
      run_provider_teardown(provider, gateway)
    end
  end

  defp run_provider_teardown(provider, gateway) do
    case provider.teardown_gateway(gateway) do
      :ok -> destroy_row(gateway)
      {:error, reason} = error -> fail(gateway, reason, error)
    end
  end

  defp remove_access_arms(instances) do
    Enum.reduce_while(instances, :ok, fn instance, :ok ->
      case remove_instance_arms(instance) do
        :ok ->
          {:cont, :ok}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  # The re-tell rides the SUCCESS branch only: a failed teardown rolled
  # its transaction back, so the pairing rows stand again and the row
  # is not gone — the app's env is not stale yet, and the retry owns
  # the convergence.
  defp post_commit_retell(_changeset, result) do
    case Process.get(@retell_key) do
      nil ->
        result

      instances ->
        Process.delete(@retell_key)
        retell_on_outcome(instances, result)
    end
  end

  defp retell_on_outcome(instances, {:ok, _gateway} = result) do
    Enum.each(instances, &retell_url_env/1)
    result
  end

  defp retell_on_outcome(_instances, {:error, _reason} = result), do: result

  # Best-effort, warn-only, per instance and independent (the lane's
  # ruling): a sync failure is logged and never fails the teardown.
  defp retell_url_env(instance) do
    case SyncInstanceUrlEnv.call(instance) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Gateway teardown: the URL-env sync failed for instance #{instance.id}: " <>
            inspect(reason)
        )

        :ok
    end
  end

  defp remove_instance_arms(instance) do
    with {:ok, kubeconfig} <- InstanceK8s.kubeconfig_for(instance) do
      EdgeRoutes.apply_access_none(kubeconfig, instance)
    end
  end

  defp destroy_row(gateway) do
    changeset =
      Ash.Changeset.for_destroy(gateway, :destroy_after_teardown, %{}, authorize?: false)

    # The return shape is transaction-context-dependent: outside a repo
    # transaction Ash delivers the publish itself and returns :ok;
    # inside one, the notifications come back for post-commit delivery.
    # Accept both rather than couple to the caller's nesting.
    result = Ash.destroy(changeset)

    case result do
      :ok ->
        {:ok, gateway}

      # The tuple shape only shows up when the destroy nests inside a
      # transaction; the suite's inline Oban teardown runs outside one,
      # so Ash delivers the publish itself and returns :ok. (A
      # single-file test run hits this arm; the full suite never does.)
      # coveralls-ignore-next-line
      {:ok, _notifications} ->
        {:ok, gateway}

      # coveralls-ignore-start - defensive: DB failure on the delete
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  # The row survives for Oban's retry — that is the whole contract here.
  # The message cannot persist from inside this transaction: a failed
  # action rolls its writes back, so the update below would vanish with
  # it. The trigger's exhaustion handler (`mark_teardown_error`) is the
  # write that lands the visible copy, one retry later; until then the
  # panel keeps showing the state the delete action set (`:destroying`).
  defp fail(gateway, reason, error) do
    Logger.error("Access gateway #{gateway.id} teardown failed: #{inspect(reason)}")
    error
  end
end
