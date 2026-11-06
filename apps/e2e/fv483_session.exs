# Dev-only capture session mint for the #483 screenshots. The #479
# invitation gate is armed in this tree, so the capture address rides
# an invite row first (bootstrap posture: authorize?: false, mirroring
# seeds — the ops surface is admin-gated and this is a local capture).
# Then the sanctioned sign-in ops mint the session exactly as a real
# signup: personal org, welcome credit, derived username. Prints the
# session token for fv483_shots.mjs / fv483_gif.mjs.
#
# Run from apps/platform: mix run ../e2e/fv483_session.exs
alias FluxVale.Ops.InvitedEmail

email = "capture-fv483@fluxvale.test"

InvitedEmail
|> Ash.Changeset.for_create(:create, %{address: email}, authorize?: false)
|> Ash.create()

code_ref = :fv483_capture_code
:persistent_term.put(code_ref, nil)

deliver = fn _recipient, code ->
  :persistent_term.put(code_ref, code)
  {:ok, %{}}
end

case FluxVale.Identity.Operations.RequestAuthCode.call(email, deliver) do
  :ok ->
    code = :persistent_term.get(code_ref, nil)

    case FluxVale.Identity.Operations.VerifyAuthCode.call(email, code) do
      {:ok, user, token} ->
        IO.puts("USERNAME=#{user.username}")
        IO.puts("TOKEN=#{token}")

      {:error, reason} ->
        IO.puts("VERIFY_ERROR=#{inspect(reason)}")
        System.stop(1)
    end

  {:error, :throttled} ->
    # The resend throttle: the actor already has a fresh code in flight,
    # which this script cannot read back. Wait out the minute.
    IO.puts("REQUEST_ERROR=throttled (a code was sent to #{email} less than 60s ago)")
    System.stop(1)

  {:error, reason} ->
    IO.puts("REQUEST_ERROR=#{inspect(reason)}")
    System.stop(1)
end
