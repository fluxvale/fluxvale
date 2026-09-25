defmodule FluxVale.Infrastructure.Instance.PerformDeploy do
  @moduledoc """
  The AshOban `:deploy` trigger's body — delegates to
  `FluxVale.Infrastructure.Operations.DeployInstance` (see there).
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.Operations.DeployInstance

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, instance ->
      DeployInstance.call(instance)
    end)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (non-atomic K8s calls in after_action)
  def atomic?, do: false
end
