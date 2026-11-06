defmodule FluxVale.Ops.InvitedEmail.ValidateAddress do
  @moduledoc """
  Rejects operator typos at write time (#478): an invitation for an
  address that can never be an email (no `local@domain` shape) would sit
  silently inert — recorded but unadmittable and unsendable. The rule is
  UserEmail's own address format (the same rule the code-send gate
  enforces), so the list can never drift from what a sign-in address
  looks like.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias FluxVale.Identity.UserEmail

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    address = Ash.Changeset.get_argument_or_attribute(changeset, :address)

    if UserEmail.valid_address?(address) do
      changeset
    else
      Ash.Changeset.add_error(
        changeset,
        InvalidAttribute.exception(
          field: :address,
          message: "must be an email address",
          value: address
        )
      )
    end
  end
end
