defmodule FluxVale.Mailer do
  @moduledoc """
  Swoosh mailer. Non-prod captures in-app via `Swoosh.Adapters.Local`
  (ADR-0003 Am. 1 / ADR-0023 Am. 3 — the gated TestInbox #22 is the only\n  sanctioned viewer; never mount the stock `/dev/mailbox` plug).
  """

  use Swoosh.Mailer, otp_app: :flux_vale

  @doc """
  The passwordless sign-in code (ADR-0003): plain body, just the code —
  transactional minimalism for deliverability.
  """
  @spec deliver_auth_code(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def deliver_auth_code(to, code) do
    %Swoosh.Email{}
    |> Swoosh.Email.to(to)
    |> Swoosh.Email.from({"FluxVale", "no-reply@fluxvale.com"})
    |> Swoosh.Email.subject("Your FluxVale sign-in code")
    |> Swoosh.Email.text_body("Your sign-in code is #{code}. It expires in 10 minutes.")
    |> deliver()
  end
end
