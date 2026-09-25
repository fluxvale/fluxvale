defmodule FluxVale.Infrastructure.Instance.PerformTeardown do
  @moduledoc """
  The AshOban `:teardown` trigger's body — delegates to
  `FluxVale.Infrastructure.Operations.TeardownInstance` (see there).
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.Operations.TeardownInstance

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, instance ->
      TeardownInstance.call(instance)
    end)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (non-atomic K8s calls in after_action)
  def atomic?, do: false
end
