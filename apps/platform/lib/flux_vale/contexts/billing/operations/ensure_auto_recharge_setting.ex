defmodule FluxVale.Billing.Operations.EnsureAutoRechargeSetting do
  @moduledoc """
  Ensures an organization has an auto-recharge setting row, creating
  one if none exists (#829 L3 — the billing pages' provisioning seam).

  Idempotent: returns the existing row when the org already has one.
  The `unique_org` identity is the concurrent-race backstop — a lost
  race surfaces as an error rather than a second row. System operation
  (runs with `authorize?: false`): members may read settings, the
  billing machinery provisions them — the EnsureWallet shape, followed
  so the billing pages can render the card without a second
  provisioning path.

  Why ensure at all (#829 L3 decision, architect): the owner's first
  write is `:set` — an UPDATE, which cannot run on a nil row, and
  creation is a system action by policy. Rather than render a
  nil-rows-off card with a dead form, the pages ensure the row at
  mount (one idempotent read-then-create) and the card always reads a
  real row.
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing.AutoRechargeSetting

  @spec call(Organization.t()) :: {:ok, AutoRechargeSetting.t()} | {:error, term()}
  def call(%Organization{} = org) do
    case AutoRechargeSetting.get_by_organization(org.id, authorize?: false) do
      {:ok, setting} ->
        {:ok, setting}

      # get? reads wrap NotFound inside Ash.Error.Invalid — a miss (the
      # realistic outcome) creates. Two concurrent first mounts race the
      # read-then-insert: the loser loses to the unique_org identity, and
      # the re-read returns the winner's row instead of an error.
      {:error, _not_found_or_failed} ->
        case AutoRechargeSetting.create(%{organization_id: org.id}, authorize?: false) do
          {:ok, setting} ->
            {:ok, setting}

          # defensive: the concurrent first-mount race — needs two
          # simultaneous creates, not sequential-test reachable
          # coveralls-ignore-start
          {:error, _conflict_or_db} ->
            AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
            # coveralls-ignore-stop
        end
    end
  end
end
