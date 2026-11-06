# Dev-only capture setup for the invitation-gate stills (#478): the
# admin PAT the TestInbox client needs (the E2E_TESTINBOX_TOKEN
# posture). Run from apps/platform:
#
#   mix run ../e2e/fv478_seed.exs
#
# Prints the token once; rerun mints a fresh one.

alias FluxVale.Identity
alias FluxVale.Identity.User

require Ash.Query

admin =
  User
  |> Ash.Query.filter(email == "admin@fluxvale.com")
  |> Ash.read_one!(authorize?: false)

{:ok, %{token: pat}} =
  Identity.mint_pat(admin, %{user_id: admin.id, name: "fv478 capture", scopes: ["catalog:read"]},
    authorize?: false)

IO.puts("FV_TESTINBOX_TOKEN=" <> pat)
