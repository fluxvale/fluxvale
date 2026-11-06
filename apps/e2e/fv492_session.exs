# Dev-only capture session mint for the #492 Pocket ID screenshots.
# Same posture as fv483_session.exs: the invite gate is armed in this
# tree, so the capture address rides an invite row first (bootstrap
# posture: authorize?: false, mirroring seeds), then the sanctioned
# sign-in ops mint the session exactly as a real signup.
#
# Run from apps/platform: mix run /tmp/opencode/fv492_session.exs
alias FluxVale.Ops.InvitedEmail

email = "capture-fv492@fluxvale.test"

InvitedEmail
|> Ash.Changeset.for_create(:create, %{address: email}, authorize?: false)
|> Ash.create()

code_ref = :fv492_capture_code
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
    IO.puts("REQUEST_ERROR=throttled (a code was sent to #{email} less than 60s ago)")
    System.stop(1)

  {:error, reason} ->
    IO.puts("REQUEST_ERROR=#{inspect(reason)}")
    System.stop(1)
end
