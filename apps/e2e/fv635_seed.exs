# #635 capture seed: the session mint plus the developer page's rows.
# Same posture as the fv492 session mint: the capture address rides the
# team-domain JIT (#502: the team bypass is the only self-signup left),
# then the sanctioned sign-in ops mint the session exactly as a real
# signup. The developer page's visible data rides the domain actions —
# one pending CLI sign-in (mint_device_code) and two PATs with
# different scopes (mint_pat) — so the captures show real rows, and no
# raw token value ever reaches the page (rows keep the hash).
#
# Run from apps/platform: mix run ../e2e/fv635_seed.exs
email = "capture-fv635@fluxvale.com"

code_ref = :fv635_capture_code
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
        {:ok, _pending} =
          FluxVale.Identity.mint_device_code(%{
            client_id: "fluxvale-cli",
            scopes: ["instances:read"]
          })

        {:ok, %{pat: _ci}} =
          FluxVale.Identity.mint_pat(user, %{
            user_id: user.id,
            name: "ci deploys",
            scopes: ["instances:read", "instances:write"]
          })

        {:ok, %{pat: _terraform}} =
          FluxVale.Identity.mint_pat(user, %{
            user_id: user.id,
            name: "terraform",
            scopes: ["gateways:read"]
          })

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
