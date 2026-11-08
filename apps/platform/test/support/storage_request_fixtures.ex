defmodule FluxVale.TestSupport.StorageRequestFixtures do
  @moduledoc """
  Preconditions for storage-request tests (#250): a request built through
  the `:request` create action (the repo's bootstrap posture — the suite
  fails loudly when the create contract changes).
  """

  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.StorageRequest
  alias FluxVale.Identity.User

  @doc """
  A request on `instance` by `actor`; `attrs` override the target,
  reason, and anything else the action accepts.
  """
  @spec request!(Instance.t(), User.t(), map()) :: StorageRequest.t()
  def request!(%Instance{} = instance, %User{} = actor, attrs \\ %{}) do
    params =
      Map.merge(
        %{
          instance_id: instance.id,
          requested_gb: 150,
          reason: "Need room for archives"
        },
        Map.new(attrs)
      )

    StorageRequest
    |> Ash.Changeset.for_create(:request, params, actor: actor)
    |> Ash.create!()
  end
end
