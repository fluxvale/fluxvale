# Dev-only capture session mint for the #450 copy-sweep screenshots.
# Drives the sanctioned sign-in ops (RequestAuthCode with a capturing
# deliver + VerifyAuthCode), so the actor is JIT-provisioned exactly as
# a real signup: personal org, welcome credit, derived username — the
# banner's preconditions (positive balance, zero instances) for free.
# Prints the session token for fv450_shots.mjs.
#
# Run from apps/platform: mix run ../e2e/fv450_session.exs

email = "capture-fv450@fluxvale.test"

code_ref = :fv450_capture_code
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
