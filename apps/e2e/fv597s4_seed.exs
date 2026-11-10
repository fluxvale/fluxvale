# Dev-only staging + capture session mint for the #597 S4 wiring
# captures (the fv597s3_seed.exs posture, extended to the leg S3
# stopped before): the offer ticked, submit, and the create → wire →
# deploy sequence — plus the wake-race choice panel. The sanctioned
# sign-in ops mint the session exactly as a real signup; staged rows
# ride the resource actions with `authorize?: false` — the repo's
# staging stance.
#
# Custody here is ROW-ONLY (S3's posture): this script runs WITHOUT
# INSTANCES_BASE_DOMAIN so the instance creates pass the platform
# hostname pattern (a port-bearing capture domain bounces the
# AccessDomain mint — the live-mint leg re-pastes the key through the
# REAL set_pocket_id_key op under the stub's env, in the capture
# driver at /tmp/opencode/fv597s4_e2e_drive.exs).
#
# PocketID layout (pinned slugs — the stub answers by host):
#   wired-id   running, custody (real op, driver)  → the mint path
#   sleepy-id  running, row-only custody           → the wake race
#              (discovery precedes the key read in the op, so the
#              stub's close kills the wiring at :unreachable before
#              any Secret is touched)
#
# Run from apps/platform:
#   mix run ../e2e/fv597s4_seed.exs
# Prints TOKEN=… PAT=… POCKETID_ID=… SLEEPY_ID=… VW_VERSION_ID=…

require Ash.Query

# The reset already ran the promotable seeds + local seeds (the
# catalog incl. Vaultwarden's recipe is in place — fv597s3's note on
# delete_removed_sizes! applies: never re-run Seeds.seed() here).
FluxVale.Seeds.seed_local_cluster!()

# The local Cluster row points at the host-run kubeconfig (#73's
# integration posture) — the seed's own custody op writes a k8s
# Secret, so it needs the cluster reachable from this mix run too.
{:ok, cluster} = FluxVale.Infrastructure.Cluster.get_by_name("local", authorize?: false)

cluster
|> Ash.Changeset.for_update(
  :update,
  %{kubeconfig_ref: "/tmp/opencode/fv597s4-k3d-kubeconfig.yaml"},
  authorize?: false
)
|> Ash.update!()

email = "capture-fv597s4@fluxvale.com"

code_ref = :fv597s4_capture_code
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

# The wallet funds the VW create (#124) — the ledger's own keying,
# idempotent by top-up (grant_credits rides an adjustment entry each
# run; a 100k-cent grant per run keeps the balance monotone and the
# gate open).
{:ok, wallet} = FluxVale.Billing.ensure_wallet(personal_org)
{:ok, _entry} = FluxVale.Billing.grant_credits(wallet, 100_000, reason: :adjustment)

# The flag, on (fail-closed default is invisible — the capture needs
# the flow). Create-or-enable, idempotent (the fv597s2 stance).
case FluxVale.Ops.FeatureFlag.by_key("pocketid_sso_wiring", authorize?: false) do
  {:ok, flag} ->
    flag
    |> Ash.Changeset.for_update(:update, %{enabled: true}, authorize?: false)
    |> Ash.update()

  {:error, _none} ->
    FluxVale.Ops.FeatureFlag.create!("pocketid_sso_wiring", %{enabled: true}, authorize?: false)
end

alias FluxVale.Infrastructure.Instance
alias FluxVale.Infrastructure.Operations.InstanceK8s

app = FluxVale.Catalog.App.get_by_slug!("pocket-id", authorize?: false)

version =
  FluxVale.Catalog.AppVersion
  |> Ash.Query.filter(app_id == ^app.id)
  |> Ash.Query.sort(created_at: :desc)
  |> Ash.read_one!(authorize?: false)

# (the fv597s3 pin!/walk_to! pattern, inlined — test/support is
# :test-only)
pocketid! = fn name, slug, deployed_days_ago ->
  instance =
    Instance.create!(
      %{
        name: name,
        app_version_id: version.id,
        env_vars: %{"ENCRYPTION_KEY" => "fv597s4-#{System.unique_integer()}"},
        organization_id: personal_org.id
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

staged_slugs = ["wired-id", "sleepy-id"]

# Wipe this run's prior staging (idempotent re-runs; custody rows
# first — the instance FK restricts while a row references them, and
# the wiring rows restrict while they reference the instance).
Instance
|> Ash.Query.filter(slug in ^staged_slugs)
|> Ash.read!(authorize?: false)
|> Enum.each(fn staged ->
  for wiring <-
        Ash.Query.filter(
          FluxVale.Infrastructure.PocketIdWiring,
          pocket_id_instance_id == ^staged.id
        )
        |> Ash.read!(authorize?: false) do
    # Their funnel is the only destroy (the resource has no default).
    FluxVale.Infrastructure.PocketIdWiring.replace(wiring, authorize?: false)
  end

  custody_rows =
    Ash.Query.filter(FluxVale.Infrastructure.PocketIdCustody, instance_id == ^staged.id)
    |> Ash.read!(authorize?: false)

  Enum.each(custody_rows, &FluxVale.Infrastructure.PocketIdCustody.revoke!(&1, authorize?: false))
  Ash.destroy!(staged, authorize?: false)
end)

wired_id = pocketid!.("Pocket ID", "wired-id", 2)
sleepy_id = pocketid!.("Pocket ID (sleepy)", "sleepy-id", 1)

# Row-only custody on both (the capture cards' stance — the real-key
# leg rides the driver). Names name Secrets that point at nothing
# until the real op stores one.
custody! = fn instance ->
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

custody!.(wired_id)
custody!.(sleepy_id)

# The app instance the wiring leg targets — created through the real
# action (the wizard's own create), left :pending for the driver's
# create → wire → deploy sequence.
vw_app = FluxVale.Catalog.App.get_by_slug!("vaultwarden", authorize?: false)

vw_version =
  FluxVale.Catalog.AppVersion
  |> Ash.Query.filter(app_id == ^vw_app.id)
  |> Ash.Query.sort(created_at: :desc)
  |> Ash.read_one!(authorize?: false)

# Prior capture instances wipe (idempotent re-runs; wiring rows
# reference the instance first).
Instance
|> Ash.Query.filter(slug == "vw-s4")
|> Ash.read!(authorize?: false)
|> Enum.each(fn staged ->
  Ash.Query.filter(FluxVale.Infrastructure.PocketIdWiring, instance_id == ^staged.id)
  |> Ash.read!(authorize?: false)
  |> Enum.each(&FluxVale.Infrastructure.PocketIdWiring.replace(&1, authorize?: false))

  Ash.destroy!(staged, authorize?: false)
end)

vw =
  Instance.create!(
    %{
      name: "VW e2e",
      app_version_id: vw_version.id,
      env_vars: %{},
      organization_id: personal_org.id
    },
    actor: user
  )

base = Ash.Changeset.for_update(vw, :update_status, %{}, authorize?: false)
vw = Ash.Changeset.force_change_attribute(base, :slug, "vw-s4") |> Ash.update!()

{:ok, %{token: pat}} =
  FluxVale.Identity.mint_pat(user, %{
    user_id: user.id,
    name: "fv597s4-capture",
    scopes: ["instances:read", "instances:write"]
  })

IO.puts("TOKEN=#{token}")
IO.puts("PAT=#{pat}")
IO.puts("POCKETID_ID=#{wired_id.id}")
IO.puts("SLEEPY_ID=#{sleepy_id.id}")
IO.puts("VW_ID=#{vw.id}")
IO.puts("VW_VERSION_ID=#{vw_version.id}")
IO.puts("ORG_ID=#{personal_org.id}")
