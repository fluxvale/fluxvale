defmodule FluxVale.Identity.User.ProvisionPersonalOrg do
  @moduledoc """
  Provisions the personal org + owner membership after a user registers
  (#119) — JIT signup auto-creates the org, the creator becomes owner,
  and no user exists without one.

  Delegates to `FluxVale.Accounts.provision_personal_org/1` (idempotent —
  safe under any re-run of the create action). Runs inside the user-create
  transaction via after_action, so a provisioning failure rolls back the
  user. Wired on the one `create` action rather than the auth flow so
  every registration path (JIT, seeds) gets an org.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      case FluxVale.Accounts.provision_personal_org(user) do
        {:ok, _org, _created?} ->
          {:ok, user}

        # coveralls-ignore-start - defensive: provisioning only fails on a
        # DB error during signup, not simulatable under the sandbox
        {:error, _error} = error ->
          error
          # coveralls-ignore-stop
      end
    end)
  end
end
