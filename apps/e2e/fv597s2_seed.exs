# Dev-only staging + capture session mint for the #597 S2 custody-card
# screenshots (the fv492_session.exs posture): the sanctioned sign-in ops
# mint the session exactly as a real signup; the PocketID instance pair
# (one with staged custody for the verified card, one fresh for the
# intake card) rides the resource actions with `authorize?: false` —
# the repo's staging stance. No real key is staged: the custody row
# references a Secret NAME only (the no-read-back discipline), and the
# fake name points at nothing.
#
# Run from apps/platform: mix run ../e2e/fv597s2_seed.exs
# Prints USERNAME=… TOKEN=… VERIFIED_INSTANCE=… FRESH_INSTANCE=…

require Ash.Query

# Promotable seeds first (idempotent): the catalog incl. pocket-id.
FluxVale.Seeds.seed()
# The local Cluster row (nil kubeconfig_ref sentinel).
FluxVale.Seeds.seed_local_cluster!()

email = "capture-fv597s2@fluxvale.com"

code_ref = :fv597s2_capture_code
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
      case FluxVale.Identity.Operations.RequestAuthCode.call(email, deliver) do
        :ok ->
          code = :persistent_term.get(code_ref, nil)

          case FluxVale.Identity.Operations.VerifyAuthCode.call(email, code) do
            {:ok, user, _token} ->
              {:ok, user}

            {:error, reason} ->
              IO.puts("VERIFY_ERROR=#{inspect(reason)}")
              System.stop(1)
          end

        {:error, :throttled} ->
          IO.puts("REQUEST_ERROR=throttled (re-run in 60s — the capture user exists)")
          System.stop(1)

        {:error, reason} ->
          IO.puts("REQUEST_ERROR=#{inspect(reason)}")
          System.stop(1)
      end
  end

# A session token for the capture browser — the same JWT the sign-in
# flow mints (VerifyAuthCode's own mechanism).
{:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

# Fund the personal org past the instance-create wallet gate, idempotent
# by ledger key (the local_seeds.exs stance).
{:ok, org} = FluxVale.Accounts.personal_org_for_user(user.id, authorize?: false)

{:ok, _entry} =
  FluxVale.Billing.credit_wallet(org, 1000, idempotency_key: "fv597s2-capture:fund")

# The flag, on (fail-closed default is invisible — the capture needs
# the card). Stage directly (capture staging, not an operator flow):
# create-or-enable, idempotent.
case FluxVale.Ops.FeatureFlag.by_key("pocketid_sso_wiring", authorize?: false) do
  {:ok, flag} ->
    :ok =
      flag
      |> Ash.Changeset.for_update(:update, %{enabled: true}, authorize?: false)
      |> Ash.update()
      |> case do
        {:ok, _row} ->
          :ok

        {:error, reason} ->
          IO.puts("FLAG_ERROR=#{inspect(reason)}")
          System.stop(1)
      end

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

mk_instance = fn name ->
  FluxVale.Infrastructure.Instance.create!(
    %{
      name: name,
      app_version_id: version.id,
      # The PocketID deploy's one required input (#492): a synthetic
      # dev-only value — env vars render on no surface, so nothing is
      # ever captured.
      env_vars: %{
        "ENCRYPTION_KEY" => "fv597s2-capture-" <> Integer.to_string(System.unique_integer())
      }
    },
    actor: user
  )
end

verified = mk_instance.("Pocket ID")
fresh = mk_instance.("Pocket ID (fresh)")

# Stage custody on ONE of the pair (the verified card's display state):
# row only, ref names a Secret that does not exist — no key anywhere.
FluxVale.Infrastructure.PocketIdCustody.record!(
  %{
    organization_id: verified.organization_id,
    instance_id: verified.id,
    api_key_secret_ref: "fluxvale-pocketid-custody-#{verified.id}",
    verified_at: DateTime.utc_now() |> DateTime.add(-3, :day),
    expires_at: DateTime.utc_now() |> DateTime.add(320, :day)
  },
  authorize?: false
)

IO.puts("USERNAME=#{user.username}")
IO.puts("TOKEN=#{token}")
IO.puts("VERIFIED_INSTANCE=#{verified.id}")
IO.puts("FRESH_INSTANCE=#{fresh.id}")
