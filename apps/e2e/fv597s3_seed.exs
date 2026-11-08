# Dev-only staging + capture session mint for the #597 S3 offer-card
# screenshots (the fv597s2_seed.exs posture): the sanctioned sign-in
# ops mint the session exactly as a real signup; the staged orgs and
# PocketID instance rows ride the resource actions with `authorize?:
# false` — the repo's staging stance. Slugs pin through the
# update_status funnel so the local probe stub can answer by host.
# No real key and no real PocketID is involved: the custody rows name
# Secrets that point at nothing, and the probe stub is a local TLS
# server on 127.0.0.1:8443 (/tmp/opencode/fv597s3_stub.py).
#
# Org layout (the wizard's picker rows, one card state each):
#   Personal        quiet-otter + spring-chime, both custody -> OFFER
#                   with picker (quiet-otter newest-deployed = default)
#   Halfway Team    half-set, custody               -> MID-SETUP
#   Offline Team    down-south, custody             -> UNREACHABLE
#   Fresh Team      a custody-less PocketID         -> NO-CUSTODY
#   Empty Team      no PocketID at all              -> plain form
#
# Run from apps/platform (the dev server must run with
# INSTANCES_BASE_DOMAIN=127.0.0.1.nip.io:8443 — see fv597s3_shots.mjs):
#   mix run ../e2e/fv597s3_seed.exs
# Prints TOKEN=… APP_SLUG=vaultwarden.

require Ash.Query

# The reset already ran the promotable seeds + local seeds (the
# catalog incl. Vaultwarden's recipe is in place); re-running
# Seeds.seed() here would trip delete_removed_sizes! against the
# local-seed demo instances' fabricated size. Only the local Cluster
# row needs ensuring (idempotent).
FluxVale.Seeds.seed_local_cluster!()

email = "capture-fv597s3@fluxvale.com"

code_ref = :fv597s3_capture_code
:persistent_term.put(code_ref, nil)

deliver = fn _recipient, code ->
  :persistent_term.put(code_ref, code)
  {:ok, %{}}
end

{:ok, user} =
  case FluxVale.Identity.User.get_by_email(email, authorize?: false) do
    {:ok, existing} ->
      {:ok, existing}

    {:error, _not_found} ->
      FluxVale.Identity.Operations.RequestAuthCode.call(email, deliver)

      code = :persistent_term.get(code_ref, nil)

      {:ok, user, _token} = FluxVale.Identity.Operations.VerifyAuthCode.call(email, code)
      {:ok, user}
  end

{:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
{:ok, personal_org} = FluxVale.Accounts.personal_org_for_user(user.id, authorize?: false)

# The flag, on (fail-closed default is invisible — the capture needs
# the card). Create-or-enable, idempotent (the fv597s2 stance).
case FluxVale.Ops.FeatureFlag.by_key("pocketid_sso_wiring", authorize?: false) do
  {:ok, flag} ->
    flag
    |> Ash.Changeset.for_update(:update, %{enabled: true}, authorize?: false)
    |> Ash.update()

  {:error, _none} ->
    FluxVale.Ops.FeatureFlag.create!("pocketid_sso_wiring", %{enabled: true}, authorize?: false)
end

# The PocketID app's newest version (seeds carry it, #597 S1).
app = FluxVale.Catalog.App.get_by_slug!("pocket-id", authorize?: false)

version =
  FluxVale.Catalog.AppVersion
  |> Ash.Query.filter(app_id == ^app.id)
  |> Ash.Query.sort(created_at: :desc)
  |> Ash.read_one!(authorize?: false)

alias FluxVale.Infrastructure.Instance
alias FluxVale.Infrastructure.Operations.InstanceK8s

# A deployed, running PocketID instance with a PINNED slug (the stub
# answers the probe by host prefix): created through the real action,
# then staged through the funnel's legal chain + forced system fields
# (the InstanceFixtures.pin!/walk_to! pattern, inlined — test/support
# is :test-only).
pocketid! = fn name, slug, org_id, deployed_days_ago ->
  instance =
    Instance.create!(
      %{
        name: name,
        app_version_id: version.id,
        env_vars: %{"ENCRYPTION_KEY" => "fv597s3-#{System.unique_integer()}"},
        organization_id: org_id
      },
      actor: user
    )

  running =
    Enum.reduce([:deploying, :starting, :running], instance, fn status, current ->
      {:ok, next} = InstanceK8s.update_status(current, status, nil)
      next
    end)

  base = Ash.Changeset.for_update(running, :update_status, %{}, authorize?: false)

  Ash.Changeset.force_change_attribute(base, :namespace, "fluxvale-app-#{instance.id}")
  |> Ash.Changeset.force_change_attribute(:slug, slug)
  |> Ash.Changeset.force_change_attribute(
    :deployed_at,
    DateTime.utc_now() |> DateTime.add(-deployed_days_ago, :day)
  )
  |> Ash.update!()
end

custody! = fn instance ->
  # Row only, ref names a Secret that does not exist — no key anywhere
  # (the no-read-back discipline; a fake name points at nothing).
  # S2's system funnel (their resource's writes are op-owned; the
  # bootstrap staging posture passes authorize?: false, their seed's
  # own stance).
  FluxVale.Infrastructure.PocketIdCustody.record!(
    %{
      organization_id: instance.organization_id,
      instance_id: instance.id,
      api_key_secret_ref: "fluxvale-pocketid-custody-#{instance.id}",
      verified_at: DateTime.utc_now() |> DateTime.add(-3, :day),
      expires_at: DateTime.utc_now() |> DateTime.add(320, :day)
    },
    authorize?: false
  )
end

staged_slugs = [
  "quiet-otter",
  "spring-chime",
  "half-set",
  "down-south",
  "plain-id"
]

# Wipe this run's prior staging (idempotent re-runs; custody rows
# first — the instance FK restricts while a row references them).
Instance
|> Ash.Query.filter(slug in ^staged_slugs)
|> Ash.read!(authorize?: false)
|> Enum.each(fn staged ->
  custody_rows =
    Ash.Query.filter(FluxVale.Infrastructure.PocketIdCustody, instance_id == ^staged.id)
    |> Ash.read!(authorize?: false)

  # Their funnel is the only destroy (the resource has no default).
  Enum.each(custody_rows, &FluxVale.Infrastructure.PocketIdCustody.revoke!(&1, authorize?: false))
  Ash.destroy!(staged, authorize?: false)
end)

quiet_otter = pocketid!.("Pocket ID", "quiet-otter", personal_org.id, 2)
spring_chime = pocketid!.("Pocket ID (old)", "spring-chime", personal_org.id, 5)
custody!.(quiet_otter)
custody!.(spring_chime)

# Find-or-create the capture teams (idempotent re-runs; the wallet
# funding rides the ledger's own keying). Test-support fixtures are
# :test-only, so the wallet lands through the domain actions the
# fixture itself wraps.
team! = fn name ->
  existing =
    FluxVale.Accounts.Organization
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(authorize?: false)

  if existing do
    existing
  else
    {:ok, org} =
      FluxVale.Accounts.create_organization(user, %{
        name: name,
        slug:
          String.replace(String.downcase(name), " ", "-") <>
            "-#{System.unique_integer([:positive])}"
      })

    {:ok, wallet} = FluxVale.Billing.ensure_wallet(org)
    {:ok, _entry} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)
    org
  end
end

halfway = team!.("Halfway Team")
offline = team!.("Offline Team")
fresh = team!.("Fresh Team")
team!.("Empty Team")

half_set = pocketid!.("Pocket ID", "half-set", halfway.id, 1)
down_south = pocketid!.("Pocket ID", "down-south", offline.id, 1)
_pocketid_only = pocketid!.("Pocket ID", "plain-id", fresh.id, 1)
custody!.(half_set)
custody!.(down_south)

IO.puts("TOKEN=#{token}")
IO.puts("APP_SLUG=vaultwarden")
