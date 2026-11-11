# Dev-only capture session mint for the #484 agent-quickstart
# screenshots: the capture address rides the team-domain JIT (#502:
# the team bypass is the only self-signup left), then the sanctioned
# sign-in ops mint the session exactly as a real signup.
#
# Run from apps/platform: mix run ../e2e/fv484_agents_session.exs
email = "capture-fv484@fluxvale.com"

code_ref = :fv484_capture_code
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
