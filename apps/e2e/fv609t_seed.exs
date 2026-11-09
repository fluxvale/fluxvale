# Dev-only staging + capture session mint for the #612 S4 takeover
# screenshots (the fv612s3_seed.exs posture): the sanctioned sign-in
# ops mint the session exactly as a real signup; the capture rows ride
# the resource actions with `authorize?: false`, the repo's staging
# stance. Nothing secret: APP_SECRET's captured value is a placeholder
# and the url_env spec is an input the wizard HIDES.
#
# Stages:
#   - the REAL seeds (the bundled "3.4.1-bundled" row converges),
#   - one capture instance on that row, walked to :running with a
#     namespace (the backup_gate_seed.exs walk), carrying the bundled
#     postgres snapshot the panel's database caveat keys on,
#   - a BackupSetting row (Ash.Seed — the row is ConfigureBackups'
#     output; the namespace Secret needs a cluster no capture touches),
#
# so the captures show: the catalog detail's two-row pricing, the
# wizard's bundled note (no DATABASE_URL input), the floored resources
# step, and the backups panel's running-snapshot caveat.
#
# Run from apps/platform against the dev DB:
#   mix run ../e2e/fv609t_seed.exs
# Prints TOKEN=… INSTANCE_ID=…

require Ash.Query

FluxVale.Seeds.seed_local_cluster!()

# The shared dev DB: pricing converges only when the ladder is absent
# (other lanes' live fixtures can block the guarded size delete).
{:ok, ladder} =
  Ash.Query.filter(FluxVale.Pricing.Size, slug == "medium")
  |> Ash.read_one(authorize?: false)

unless ladder, do: FluxVale.Seeds.seed_pricing!()
FluxVale.Seeds.seed_catalog!()

email = "capture-fv609t@fluxvale.com"

code_ref = :fv609t_capture_code
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

# Idempotent re-runs: wipe this script's prior instance (its version
# row is the seeds' to converge, never destroyed here).
# The staged BackupSetting goes first (its FK sits on the instance).
for instance <-
      FluxVale.Infrastructure.Instance
      |> Ash.Query.filter(name == "Umami takeover capture")
      |> Ash.read!(authorize?: false) do
  for setting <-
        FluxVale.Infrastructure.BackupSetting
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.read!(authorize?: false) do
    Ash.destroy!(setting, authorize?: false)
  end

  Ash.destroy!(instance, authorize?: false)
end

versions =
  "umami"
  |> FluxVale.Catalog.App.get_by_slug!(authorize?: false)
  |> Ash.load!([:app_versions], authorize?: false)
  |> Map.fetch!(:app_versions)

bundled = Enum.find(versions, &(&1.version == "3.4.1-bundled"))

instance =
  FluxVale.Infrastructure.Instance.create!(
    %{
      name: "Umami takeover capture",
      app_version_id: bundled.id,
      env_vars: %{"APP_SECRET" => "capture-placeholder-secret-0123456789abcdef"}
    },
    actor: user,
    authorize?: false
  )

{:ok, deploying} =
  FluxVale.Infrastructure.Operations.InstanceK8s.update_status(instance, :deploying, nil)

pinned =
  deploying
  |> Ash.Changeset.for_update(:update_status, %{}, authorize?: false)
  |> Ash.Changeset.force_change_attribute(:namespace, "fluxvale-app-#{instance.id}")
  |> Ash.update!()

Enum.reduce([:starting, :running], pinned, fn status, acc ->
  {:ok, next} = FluxVale.Infrastructure.Operations.InstanceK8s.update_status(acc, status, nil)
  next
end)

case FluxVale.Infrastructure.BackupSetting
     |> Ash.Query.filter(instance_id == ^instance.id)
     |> Ash.read_one!(authorize?: false) do
  nil ->
    Ash.Seed.seed!(FluxVale.Infrastructure.BackupSetting, %{
      instance_id: instance.id,
      endpoint: "https://account.r2.cloudflarestorage.com",
      bucket: "capture-umami",
      access_key_id: "AKIAIOSFODNN7EXAMPLE"
    })

  _existing ->
    :ok
end

IO.puts("TOKEN=#{token}")
IO.puts("INSTANCE_ID=#{instance.id}")
