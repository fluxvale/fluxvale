# Dev-only capture setup for the #557 type-system visual gate. Mints:
#   - the seed admin's session token (admin console, settings)
#   - a token for the owner of a seeded instance (instance page)
#     — instances have no user FK, the org is the ownership axis
#     (#119): resolve personal_org -> user.
# Prints FV_TOKEN_ADMIN=… / FV_TOKEN_USER=… / INSTANCE_PATH=… lines.
#
# Run from apps/platform: mix run ../e2e/fv557_type_seed.exs

alias AshAuthentication.Jwt
alias FluxVale.Identity.User
alias FluxVale.Infrastructure.Instance

require Ash.Query

admin = User.get_by_email!("admin@fluxvale.com", authorize?: false)
{:ok, admin_token, _} = Jwt.token_for_user(admin)
IO.puts("FV_TOKEN_ADMIN=#{admin_token}")

instances = Ash.read!(Instance, authorize?: false)
instance = Enum.find(instances, &(&1.namespace != nil)) || List.first(instances)

if instance do
  org = Ash.load!(instance, :organization, authorize?: false).organization

  # Personal orgs carry the owner id explicitly (#408).
  owner_id = Map.get(org, :personal_owner_id)

  user =
    if owner_id do
      User
      |> Ash.Query.filter(id == ^owner_id)
      |> Ash.read_one!(authorize?: false)
    else
      [membership] =
        FluxVale.Accounts.Membership
        |> Ash.Query.filter(organization_id == ^org.id)
        |> Ash.read!(authorize?: false)

      Ash.load!(membership, :user, authorize?: false).user
    end

  {:ok, user_token, _} = Jwt.token_for_user(user)
  IO.puts("FV_TOKEN_USER=#{user_token}")
  IO.puts("INSTANCE_PATH=/instances/#{instance.id}")
else
  IO.puts("NO-INSTANCE")
end
