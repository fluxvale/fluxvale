defmodule FluxVale.Infrastructure.Instance.PerformReconcile do
  @moduledoc """
  The AshOban `:reconcile_status` trigger's body — delegates to
  `FluxVale.Infrastructure.Operations.ReconcileInstance` (see there).
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.Operations.ReconcileInstance

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, instance ->
      ReconcileInstance.call(instance)
    end)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (non-atomic K8s reads in after_action)
  def atomic?, do: false
end
