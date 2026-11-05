# Member-lifecycle capture seed (slice 5 of #408): a real org with an
# owner, one plain member, and a pending invite — plus session tokens
# for the owner and the member actors, minted through the sanctioned
# sign-in ops (RequestAuthCode with a capturing deliver + VerifyAuthCode),
# so both actors are JIT-provisioned exactly as a real signup. Prints
# OWNER_TOKEN, MEMBER_TOKEN, ORG_PATH for members_lifecycle_shots.mjs.
#
# Dev-only capture tooling: rows are unique-per-run and land in the dev
# DB. Run from apps/platform: mix run ../e2e/members_lifecycle_seed.exs

n = System.system_time(:microsecond)

owner_email = "capture-owner-#{n}@fluxvale.test"
member_email = "capture-member-#{n}@fluxvale.test"

defmodule MembersLifecycleSeed do
  # The sign-in ops' mail hook: capture the code, never send.
  def sign_in!(email) do
    code_ref = :"members_lifecycle_#{email}"
    :persistent_term.put(code_ref, nil)

    deliver = fn _recipient, code ->
      :persistent_term.put(code_ref, code)
      {:ok, %{}}
    end

    :ok = FluxVale.Identity.Operations.RequestAuthCode.call(email, deliver)
    code = :persistent_term.get(code_ref, nil)

    case FluxVale.Identity.Operations.VerifyAuthCode.call(email, code) do
      {:ok, user, token} ->
        {user, token}

      {:error, reason} ->
        IO.puts("VERIFY_ERROR=#{inspect(reason)}")
        System.stop(1)
    end
  end
end

alias FluxVale.Accounts
alias FluxVale.Accounts.Membership
alias FluxVale.Accounts.Organization

{owner, owner_token} = MembersLifecycleSeed.sign_in!(owner_email)
{member, member_token} = MembersLifecycleSeed.sign_in!(member_email)

# Org + memberships ride the actions with authorize?: false — the dev
# capture posture (the seeds' bootstrap stance; the gates under capture
# are the lifecycle affordances, not the creates).
org =
  Organization.create!(%{name: "Northwind Labs", slug: "northwind-labs-#{n}"},
    authorize?: false
  )

Membership.create!(%{organization_id: org.id, user_id: owner.id, role: :owner},
  authorize?: false
)

Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
  authorize?: false
)

# A pending invite row so the owner's queue renders with content.
{:ok, _invite} = Accounts.invite_member(owner, org, "watcher-#{n}@fluxvale.test")

IO.puts("OWNER_TOKEN=#{owner_token}")
IO.puts("MEMBER_TOKEN=#{member_token}")
IO.puts("ORG_PATH=/organizations/#{org.slug}/settings/members")
