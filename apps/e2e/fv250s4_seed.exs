# Dev-only staging + capture session mint for the #250 S4 member
# storage-request screenshots (the fv597s3_seed.exs posture): the
# sanctioned sign-in ops mint the session exactly as a real signup; the
# instance rows and the one open/rejected request ride the resource
# actions with `authorize?: false` only where the operator arm is the
# precondition (the rejection is a real admin decision).
#
# Three instances, one card state each:
#   Capture storage free        no request        -> boundary + Request more
#   Capture storage requested   open request      -> Awaiting review card
#   Capture storage rejected    rejected request  -> feedback card
#
# Run from apps/platform (a dev server on 127.0.0.1:4000):
#   mix run ../e2e/fv250s4_seed.exs
# Prints TOKEN=… and the three instance ids.

require Ash.Query

email = "capture-fv250s4@fluxvale.com"

code_ref = :fv250s4_capture_code
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

admin_email = "capture-fv250s4-admin@fluxvale.com"

admin =
  case FluxVale.Identity.User.get_by_email(admin_email, authorize?: false) do
    {:ok, existing} ->
      existing

    {:error, _not_found} ->
      FluxVale.Identity.User.create!(admin_email, %{platform_role: :admin}, authorize?: false)
  end

app = FluxVale.Catalog.App.get_by_slug!("forgejo", authorize?: false)

version =
  FluxVale.Catalog.AppVersion
  |> Ash.Query.filter(app_id == ^app.id)
  |> Ash.Query.sort(created_at: :desc)
  |> Ash.read_one!(authorize?: false)

# Repeatable capture: drop prior capture rows (dev only; the request
# rows cascade with their instance).
FluxVale.Infrastructure.Instance
|> Ash.Query.filter(contains(name, "Capture storage"))
|> Ash.read!(authorize?: false)
|> Enum.each(&Ash.destroy!(&1, authorize?: false))

# :stopped is the state the status reconciler leaves alone (its trigger
# mirrors only deploying/starting/running), so the card stays available
# on a long-lived page.
make_instance = fn name ->
  instance =
    FluxVale.Infrastructure.Instance.create!(
      %{name: name, app_version_id: version.id},
      actor: user
    )

  Enum.reduce([:deploying, :starting, :running, :stopped], instance, fn status, current ->
    {:ok, next} =
      FluxVale.Infrastructure.Operations.InstanceK8s.update_status(current, status, nil)

    next
  end)
end

free = make_instance.("Capture storage free")

requested = make_instance.("Capture storage requested")

requested_request =
  FluxVale.Infrastructure.StorageRequest
  |> Ash.Changeset.for_create(
    :request,
    %{
      instance_id: requested.id,
      requested_gb: 200,
      reason: "We're archiving this year's field recordings and need room to keep them."
    },
    actor: user
  )
  |> Ash.create!()

rejected = make_instance.("Capture storage rejected")

rejected_request =
  FluxVale.Infrastructure.StorageRequest
  |> Ash.Changeset.for_create(
    :request,
    %{
      instance_id: rejected.id,
      requested_gb: 400,
      reason: "Trying to fit the whole media library on one box."
    },
    actor: user
  )
  |> Ash.create!()

{:ok, _rejected} =
  FluxVale.Infrastructure.StorageRequest.reject(
    rejected_request,
    %{
      rejection_reason:
        "We can't attach that much capacity to this box yet. Ask for 250 GB and we can order it."
    },
    actor: admin
  )

IO.puts("TOKEN=#{token}")
IO.puts("FV_FREE=#{free.id}")
IO.puts("FV_REQUESTED=#{requested.id}")
IO.puts("FV_REJECTED=#{rejected.id}")
IO.puts("FV_REQUEST_ID=#{requested_request.id}")
